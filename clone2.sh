#!/bin/bash
#
#  This script is intended and shared as an example of Azure CLI commands used to accomplish a specific use case.
#  It is NOT intended to be used in any production environment and no guarantee or SLA is provided or implied by Microsoft or the individual(s) who authored or shared it.
#  Use of this script should be limited to proof-of-concept work only within a non-production environment.
#  Please consider this script to be an informational example only - use at your own risk.
#
#

#set -x

usage() { echo "Usage: $0 [-g <resource-group>] [-n <vmname>]" 1>&2; exit 1; }

##  Receive parameters
while getopts ":g:n:" o; do
    case "${o}" in
        g)
            RESGRP=${OPTARG}
            ;;
        n)
            VMNAME=${OPTARG}
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

if [ -z "${RESGRP}" ] || [ -z "${VMNAME}" ]; then
    usage
fi

## Record timestamp for storage resource naming
TIMESTAMP=`date +"%Y%m%d%H%M%S"`

##  Query Source VM information
VM=`az vm show -g $RESGRP -n $VMNAME --query "{Name:name,Location:location,Size:hardwareProfile.vmSize,OSType:storageProfile.osDisk.osType,OSDisk:storageProfile.osDisk.name,DataDisks:storageProfile.dataDisks[].name,DataDiskUri:storageProfile.dataDisks[].vhd.uri}"`

##  Extract relevant data points from JSON
VMSIZE=`echo $VM | jq -c '.Size' |sed "s/\"//g" `
LOCATION=`echo $VM | jq -c '.Location' |sed "s/\"//g" `
OSTYPE=`echo $VM | jq -c '.OSType' |sed "s/\"//g" `
OSDISK=`echo $VM | jq -c '.OSDisk' | sed "s/\"//g" `
DATADISKS=`echo $VM | jq -c '.DataDisks[]' |sed "s/\"//g" `

##  Create OS Disk snapshot
az snapshot create --location $LOCATION -g $RESGRP -n ${OSDISK}_${TIMESTAMP} --source $OSDISK  --sku Premium_LRS

##  Create Data Disk snapshots
for DDISK in $DATADISKS
do
   az snapshot create --location $LOCATION -g $RESGRP -n ${DDISK}_${TIMESTAMP} --source $DDISK --sku Premium_LRS
done

## Add sleep to give snapshots a chance to get started
sleep 5

##  Check status of background snapshot creation
echo "Waiting while snapshots are taken from source VM disks"
SNAPRUN=`az snapshot list --query "[?contains(name,'_${TIMESTAMP}')].{Name:name,Status:provisioningState}" -o tsv | egrep -c -v "\s+Succeeded"`
while [ ${SNAPRUN} -gt 0 ]
do
   printf "%s" "\."
   SNAPRUN=`az snapshot list --query "[?contains(name,'_${TIMESTAMP}')].{Name:name,Status:provisioningState}" -o tsv | egrep -c -v "\s+Succeeded"`
   sleep 3
done

## Create VHD from OS Disk snapshot
az disk create --location $LOCATION -g $RESGRP -n ${OSDISK}_${TIMESTAMP}disk --source ${OSDISK}_${TIMESTAMP} --no-wait

## Create VHDs from DATA Disk snapshots
for DDISK in $DATADISKS
do
    az disk create --location $LOCATION -g $RESGRP -n ${DDISK}_${TIMESTAMP}disk --source ${DDISK}_${TIMESTAMP} --no-wait
    ## Build list of data disks for reference later
    VMDDISKLIST="$VMDDISKLIST ${DDISK}_${TIMESTAMP}disk"
done

## Add sleep to give VHD copies a chance to get started
sleep 5

##  Check status of background disk creation
echo "Waiting while disks are generated from snapshots"
DISKRUN=`az disk list --query "[?contains(name,'_${TIMESTAMP}')].{Name:name,Status:provisioningState}" -o tsv | egrep -c -v "\s+Succeeded"`
while [ ${DISKRUN} -gt 0 ]
do
   printf "%s" "\."
   DISKRUN=`az disk list --query "[?contains(name,'_${TIMESTAMP}')].{Name:name,Status:provisioningState}" -o tsv | egrep -c -v "\s+Succeeded"`
   sleep 3
done

## Create VM and attach disks
az vm create -g $RESGRP -n ${VMNAME}-copy --size $VMSIZE --location $LOCATION --os-type $OSTYPE --attach-os-disk ${OSDISK}_${TIMESTAMP}disk --attach-data-disks $VMDDISKLIST

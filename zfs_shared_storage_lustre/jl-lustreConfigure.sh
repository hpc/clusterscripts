#!/bin/bash
#

#
# Global variable declarations.
#
declare -a MGS_ZPOOLS		# base indexed array, 0-based
declare -a MDS_ZPOOLS		# base indexed array, 0-based
declare -a OSS_ZPOOLS		# bash indexed array, 0-based

#
# Source this file to define the Lustre configuration variables we will need
# in this script to execute the commands to create that configuration.
#
if [ ! -e ./jl-lustreConfigDefs.sh ]; then
  echo "The configuration definition file, jl-lustreConfigDefs.sh, is not found. It must exist."
  exit 1
else
  . ./jl-lustreConfigDefs.sh
fi

#
# Source this file to get the current Lustre configuration name. If it's the
# same as the one that is to be defined, we simply re-establish that Lustre
# configuration. Otherwise, we'll delete the current configuration and establish
# the one to be defined.
#
if [ ! -e ./jl-lustreCurrentConfigName.sh ]; then
  currentConfigName=""
else
  . ./jl-lustreCurrentConfigName.sh
fi
#echo "The current Lustre configuration name is \"${currentConfigName}\"."


################################################################################
#
# The main execution control of this file starts below here. Above were
# variable and function declarations that are used by this file.
#
################################################################################

#
# When a node comes up without entries in the /etc/fstab, these commands have 
# been completed:
#
# zpool create -f mgt1pool sdb
# zpool create -f mdt1pool sdc
# mkfs.lustre --mgs --fsname=lustre1 mgt1pool/mgt1 /mgt1pool
# mkfs.lustre --mdt --fsname=lustre1 --mgsnode=lustre-mds1@tcp1 --index=0 mdt1pool/mdt1 /mdt1pool
#
#
# You see the ZFS zpools from the zpool create commands:
#
#[root@lustre-mds1 ~]# zpool list
#NAME       SIZE  ALLOC   FREE    CAP  DEDUP  HEALTH  ALTROOT
#mdt1pool  1.98G  2.62M  1.98G     0%  1.00x  ONLINE  -
#mgt1pool  1008M  1.99M  1006M     0%  1.00x  ONLINE  -
#
#
# You see the ZFS file systems from the mkfs.lustre commands:
#[root@lustre-mds1 ~]# zfs list
#
#NAME            USED  AVAIL  REFER  MOUNTPOINT
#mdt1pool       2.58M  1.95G    30K  /mdt1pool
#mdt1pool/mdt1  2.27M  1.95G  2.27M  /mdt1pool/mdt1
#mgt1pool       1.97M   974M    30K  /mgt1pool
#mgt1pool/mgt1  1.83M   974M  1.83M  /mgt1pool/mgt1
#
#
# You see the mounted ZFS file systems from the zpool create commands, but you
# do not see the mounted Lustre file systems from the mount -t lustre...
# commands:
#
#[root@lustre-mds1 ~]# df -h
#Filesystem            Size  Used Avail Use% Mounted on
#mdt1pool              2.0G     0  2.0G   0% /mdt1pool
#mgt1pool              974M     0  974M   0% /mgt1pool
#

#
# Figure out what class of node this host is. By this we know how to
# configure it. In a Lustre file system, a node is one of:
#
# MGS: Management Server
# MDS: Metadata Server
# MGS_MDS: Node that serves as both a Management & Metadata Server
# OSS: Oject Storage Server
#

thisHost=`hostname`
#echo "The hostname from the hostname command is \"$thisHost\"."

if [[ "$thisHost" =~ ((([a-zA-Z]|[a-zA-Z][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z]|[A-Za-z][A-Za-z0-9\-]*[A-Za-z0-9])) ]]; then
   shortHostname=`echo $thisHost | awk -F '.' '{print $1}'`
fi
#echo "The short hostname is \"${shortHostname}\"."

hostClass=''

#
# Now that we have the hostname without any domain extension on it...
#
# OSSs are the most common nodes in a Lustre file system, so check
# to see if it's one of those first.
#
for i in "${OSS_hosts[@]}"; do
  if [ "$i" == "$shortHostname" ]; then
    hostClass='OSS'
  fi
done

#
# MDSs are the next most common nodes in a Lustre file system.
#
# If it wasn't an OSS, let's see if it's a MDS.
#
if [ "$hostClass" == "" ]; then
  for i in "${MDS_hosts[@]}"; do
    if [ "$i" == "$shortHostname" ]; then
      hostClass='MDS'
    fi
  done
fi

#
# If it wasn't a MDS, let's see if it's a MGS_MDS.
#
if [ "$hostClass" == "" ]; then
  for i in "${MGS_MDS_hosts[@]}"; do
    if [ "$i" == "$shortHostname" ]; then
      hostClass='MGS_MDS'
    fi
  done
fi

#
# If it wasn't a MGS_MDS, let's see if it's a MGS.
#
if [ "$hostClass" == "" ]; then
  for i in "${MGS_hosts[@]}"; do
    if [ "$i" == "$shortHostname" ]; then
      hostClass='MGS'
    fi
  done
fi
#echo "This host's class is \"${hostClass}\"."

if [ "$hostClass" == "" ]; then
  echo "Host \"${shortHostname}\" is not a host in this Lustre configuration."
  exit 1
fi


#
# Figure out if we are re-establishing the current configuration or deleting
# the current one and establishing a new one.
#
if [ "$currentConfigName" == "$configName" ]; then
  echo "Re-establishing configuration \"$configName\"..."
else
  echo "Establishing new configuration \"$configName\"..."

  case $hostClass in
    MGS)
      mgsZpoolCreate
      mgsFormatZFSfromZpool
      mgsMountZFSfromZpool
      ;;
    MDS)
      mdsZpoolCreate
      mdsFormatZFSfromZpool
      mdsMountZFSfromZpool
      ;;
    MGS_MDS)
      mgs_mdsZpoolCreate
      mdsFormatZFSfromZpool
      mdsMountZFSfromZpool
      ;;
    OSS)
      case $zLevel in
        [1-3])
          echo "RAIDZ level is ${zLevel}"
          ;;
        *)
          echo "Invalid RAIDZ level of ${zLevel}"
          exit 1
          ;;
      esac

#@@@
      ossZpoolsCreate
#
# Base zpool names on the host, its type (ost), and which pool of the host
# this is, from 1 .. n, were n is the max number of pools this node can support.
# That is based on how many devices are connected to it and how many devices
# per zpool, which depends on how many data devices and parity devices a zpool
# has.
#
# zpool create -f ${shortHostname}-ost-zpool${i} raidz${zLevel} <device-list-of-dataDevice+zLevel-devices>
#   ...
# zpool create -f ${shortHostname}-ost-zpool${i} raidz${zLevel} <device-list-of-dataDevice+zLevel-devices>

      ossFormatZFSfromZpool
# 
# Loop over FSbaseName and do two mkfs.lustre --ost ... for each FSbaseName.
#
# Do the same for each OST. I'll have to think about how to use the variables here to create
# the correct naming scheme.
#
# mkfs.lustre --ost --fsname=lustre1 --mgsnode=lustre-mds1@tcp1 --index=0 ost1-1pool/ost1-1 /ost1-1pool
# mkfs.lustre --ost --fsname=lustre2 --mgsnode=lustre-mds2@tcp1 --index=0 ost1-1pool/2ost1-1 /ost1-1pool
# mkfs.lustre --ost --fsname=lustre1 --mgsnode=lustre-mds1@tcp1 --index=1 ost1-2pool/ost1-2 /ost1-2pool
# mkfs.lustre --ost --fsname=lustre2 --mgsnode=lustre-mds2@tcp1 --index=1 ost1-2pool/2ost1-2 /ost1-2pool

      ossMountZFSfromZpool
#
# Now we need to make the mount points and mount them too. I'm out of time right now.
#
      ;;
  esac
fi

exit 0

################################################################################
#
# We create a ZFS zpool consisting of a single storage device that will become
# the storage for the MGT.
#
################################################################################
function mgsZpoolCreate () {

  for i in $( ls /dev/sd* ); do
#    echo "sd device is \"${i}\"."

    if [ "${i}" == "/dev/sda" ]; then
#
# Base zpool name on the node's name and the type of node (MGS).
#
      zpool create -f ${shortHostname}-mgt-zpool ${i}

      break
    fi
  done
}

################################################################################
#
# Format the zpool as a ZFS file system to be the MGS's MGT.
#
################################################################################
function mgsFormatZFSfromZpool () {

#
# Base the Lustre "--fsname" and ZFS file system name on FSbaseName.
#

  for fs in $( echo $FSbaseNames ); do
#    echo "File system base name of \"${fs}\" processed."
    if [ "${MGS_hosts[${fs}]}" == "${shortHostname}" ]; then
      mkfs.lustre \
        --mgs \
        --fsname=lustre-${fs} \
        ${shortHostname}-mgt-zpool/mgt-${fs} \
        /${shortHostname}-mgt-zpool

      break
    fi
  done
}

################################################################################
#
# Mount the ZFS file system.
#
################################################################################
function mgsMountZFSfromZpool () {

#
# Base the mount point on FSbaseName.
#

  for fs in $( echo $FSbaseNames ); do
#    echo "File system base name of \"${fs}\" processed."
    if [ "${MGS_hosts[${fs}]}" == "${shortHostname}" ]; then
      mkdir -p /mnt/mgt-${fs}
      mount -t lustre ${shortHostname}-mgt-zpool/mgt-${fs} /mnt/mgt-${fs}

      break
    fi
  done
}

################################################################################
#
# We create a ZFS zpool consisting of a single storage device that will become
# the storage for the MDT.
#
################################################################################
function mdsZpoolCreate () {

#
# Get all of the storage device names that are available to be put into zpools
# for a MDT on this node.
#
  for i in $( ls /dev/sd* ); do
#    echo "sd device is \"${i}\"."

    if [ "${i}" == "/dev/sda" ]; then
      zpool create -f ${shortHostname}-mdt-zpool ${i}

      break
    fi
  done
}

################################################################################
#
# Format the zpool as a ZFS file system to be the MDS's MDT.
#
################################################################################
function mdsFormatZFSfromZpool () {

#
# Base the Lustre "--fsname" and ZFS file system name on FSbaseName.
#

  for fs in $( echo $FSbaseNames ); do
#    echo "File system base name of \"${fs}\" processed."
    if [ "${MDS_hosts[${fs}]}" == "${shortHostname}" ]; then
      mkfs.lustre \
        --mdt \
        --fsname=lustre-${fs} \
        --mgsnode=$MGS_hosts[${fs}]@tcp1 \
        --index=0 \
        ${shortHostname}-mdt-zpool/mdt-${fs} \
        /${shortHostname}-mdt-zpool

      break
    fi
  done
}

################################################################################
#
# Mount the ZFS file system.
#
################################################################################
function mdsMountZFSfromZpool () {

#
# Base the mount point on FSbaseName.
#

  for fs in $( echo $FSbaseNames ); do
#    echo "File system base name of \"${fs}\" processed."
    if [ "${MDS_hosts[${fs}]}" == "${shortHostname}" ]; then
      mkdir -p /mnt/mdt-${fs}
      mount -t lustre ${shortHostname}-mdt-zpool/mdt-${fs} /mnt/mdt-${fs}

      break
    fi
  done
}

################################################################################
#
# We create a ZFS zpool consisting of a single storage device that will become
# the storage for the MGT.
#
# We also create a ZFS zpool consisting of a single storage device that will
# become the storage for the MDT.
#
# Both the MGT and the MDT are hosted on this node, as is acts as both types
# of server.
#
################################################################################
function mgs_mdsZpoolCreate () {

  for i in $( ls /dev/sd* ); do
#    echo "sd device is \"${i}\"."

    if [ "${i}" == "/dev/sda" ]; then
      zpool create -f ${shortHostname}-mgt-zpool ${i}
    elif [ "${i}" == "/dev/sdb" ]; then
      zpool create -f ${shortHostname}-mdt-zpool ${i}
    fi
  done
}

################################################################################
#
# Format the zpools as ZFS file systems to be the MGS's MGT and the MDS's MDT.
#
################################################################################
function mgs_mdsFormatZFSfromZpool () {

#
# Base the Lustre "--fsname" and ZFS file system name on FSbaseName.
#

  for fs in $( echo $FSbaseNames ); do
#    echo "File system base name of \"${fs}\" processed."
    if [ "${MGS_MDS_hosts[${fs}]}" == "${shortHostname}" ]; then
      mkfs.lustre \
        --mgs \
        --fsname=lustre-${fs} \
        ${shortHostname}-mgt-zpool/mgt-${fs} \
        /${shortHostname}-mgt-zpool

      mkfs.lustre \
        --mdt \
        --fsname=lustre-${fs} \
        --mgsnode=$MGS_MDS_hosts[${fs}]@tcp1 \
        --index=0 \
        ${shortHostname}-mdt-zpool/mdt-${fs} \
        /${shortHostname}-mdt-zpool

      break
    fi
  done
}


################################################################################
#
# Mount the ZFS file systems.
#
################################################################################
function mgs_mdsMountZFSfromZpool () {

#
# Base the mount points on FSbaseName.
#

  for fs in $( echo $FSbaseNames ); do
#    echo "File system base name of \"${fs}\" processed."
    if [ "${MGS_MDS_hosts[${fs}]}" == "${shortHostname}" ]; then
      mkdir -p /mnt/mgt-${fs}
      mount -t lustre ${shortHostname}-mgt-zpool/mgt-${fs} /mnt/mgt-${fs}

      mkdir -p /mnt/mdt-${fs}
      mount -t lustre ${shortHostname}-mdt-zpool/mdt-${fs} /mnt/mdt-${fs}

      break
    fi
  done
}

################################################################################
#
# This function creates the ZFS zpools for an OSS.
#
# It may be desirable to use a separate device for the ZFS Intent Log to get
# better performance when the data that is written needs to be on stable
# storage devices. By default it is allocated from blocks of the devices used
# in the pool. One may wish to use a NVM device for this purpose. Add the "log"
# keyword and the device name to be used for the log.
#
# It may be desirable to use a separated device for a cache to get better
# performance for random read workloads whose data is mainly static. Again,
# this may be best served by a NVM device. Add the "cache" keyword and the
# device name to be used for the cache.
#
################################################################################
function ossZpoolsCreate () {

  zpoolsCreated=0

#
# Get all of the storage device names that are available to be put into zpools
# on this node.
#
  for i in $( ls /dev/sd* ); do
    echo "sd device is \"${i}\"."
  done

#
# Loop until not enough devices left to build a ZFS zpool.
#
# Build a string of the devices that consists of ( dataDevices + zLevel ) of
# them. Then create the ZFS zpool with that string.
#
#  zpool create -f <pool-name> <raidz1 or raidz2 or raidz3> <device-name-string>

#
# After creating a zpool, count it.
#
  zpoolsCreated=`expr ${zpoolsCreated} + 1`

  for (( i=1; i <= zpoolsCreated; i++ )); do
    echo "${i} - mkfs.lustre ..."
  done
}

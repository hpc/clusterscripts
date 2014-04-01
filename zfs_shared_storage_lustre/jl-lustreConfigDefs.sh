#!/bin/bash

#
# Define the essential parameters for the Lustre configuration to be implemented.
#
# The configuration name is the key. This value will be compared against the
# current configuration name to tell whether the current configuration should
# be deleted and replaced with a new one.
#
configName="yetiTwoFS"
#echo $configName

#
# The file system base names provide a means for creating unique names for the
# ZFS zpools, ZFS file systems, Lustre file systems, and mount points.
#
FSbaseNames="ylw trq"
#echo $FSbaseNames

#
# The OSTs will be created on top of ZFS zpools with RAIDz. The "z" level tells
# how many parity devices to use.
#
zLevel=2
#echo $zLevel

#
# The OSTs need data devices also. The total size of the RAIDz is the number
# of parity devices plus the number of data devices.
#
dataDevices=8
#echo $dataDevices

#
# Bash indexed arrays, 0-based, that hold the host names of the nodes that
# fill various roles.
#
declare -a MGS_hosts
MGS_hosts=(mallorca)

declare -a MDS_hosts

declare -a MGS_MDS_hosts
MGS_MDS_hosts=(jl-mds01 jl-mds02)

declare -a OSS_hosts
OSS_hosts=(jl-oss01 jl-oss02)

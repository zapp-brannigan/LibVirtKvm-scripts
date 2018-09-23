#!/usr/bin/env bash
#
# This file is part of fi-backup.
#
# fi-backup is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# fi-backup is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with fi-backup.  If not, see <http://www.gnu.org/licenses/>.
#
# fi-backup - Online Forward Incremental Libvirt/KVM backup
# Copyright (C) 2013 2014 2015 Davide Guerri - davide.guerri@gmail.com
#
# Forked in 2018 by Zapp-Brannigan (fuerst.reinje@web.de)
#
export LANG=C

if [ `id -u` -ne 0 ];then
   echo -e "$(date +%Y-%m-%d_%H:%M:%S) [ERR] Please run this script as superuser"
   exit 1
fi

VERSION="2.1.0.1"
APP_NAME="fi-backup"
SNAPSHOT=1
CONSOLIDATION_SET=0

# Fail if one process fails in a pipe
set -o pipefail

# Executables
QEMU_IMG="/usr/bin/qemu-img"
VIRSH="/usr/bin/virsh"
QEMU="/usr/bin/qemu-system-x86_64"
SYSTEMD_CAT="/usr/bin/systemd-cat"
executables=("rsync" "uuidgen" "hexdump" "sed")
for i in ${executables[@]};do
  which $i > /dev/null 2>&1
  if [ $? -ne 0 ];then
     _ret=1
     echo "Excutable '$i' not found, please install it"
     return
  fi
done

source fi-backup.conf > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "$(date +%Y-%m-%d_%H:%M:%S) [ERR] fi-backup.conf not found!"
    exit 1
fi
source utils.sh > /dev/null 2>&1
if [ $? -ne 0 ]; then
    echo -e "$(date +%Y-%m-%d_%H:%M:%S) [ERR] utils.sh not found!"
    exit 1
fi
TEMP=$(getopt -n "$APP_NAME" -o b:cCm:s:qdhvVSHlR --long method:,quiesce,debug,help,version,verbose,stdout,housekeeping,list-backups,restore,as-copy -- "$@")
if [ $? != 0 ] ; then echo "Failed parsing options." >&2 ; exit 1 ; fi

eval set -- "$TEMP"
while true; do 
   case "$1" in 
      -b)
        BACKUP_DIRECTORY=$2
        if [ ! -d "$BACKUP_DIRECTORY" ]; then
           print_v e "Backup directory '$BACKUP_DIRECTORY' doesn't exist!"
           exit 1
        fi
        shift; shift
      ;;
      -c)
         if [ ! -z ${CONSOLIDATION+x} ] && [ $CONSOLIDATION -eq 1 ]; then
            print_usage "-c or -C already specified!"
          exit 1
         fi
         CONSOLIDATION=1
         SNAPSHOT=0
         shift
      ;;
      -C)
         if [ ! -z ${CONSOLIDATION+x} ] && [ $CONSOLIDATION -eq 1 ]; then
            print_usage "-c or -C already specified!"
         exit 1
         fi
         CONSOLIDATION=1
         SNAPSHOT=1
         shift
      ;;
      -m|--method)
         CONSOLIDATION_METHOD=$2
         CONSOLIDATION_SET=1
         if [ "$CONSOLIDATION_METHOD" == "blockcommit" ]; then
            CONSOLIDATION_FLAGS=(--wait --pivot --active)
         elif [ "$CONSOLIDATION_METHOD" == "blockpull" ]; then
            CONSOLIDATION_FLAGS=(--wait)
         else
            print_usage "-m requires specifying 'blockcommit' or 'blockpull'"
            exit 1
         fi
         shift;shift
      ;;
      -q|--quiesce)
         QUIESCE=1
         shift
      ;;
      -s)
         DUMP_STATE=1
         DUMP_STATE_DIRECTORY=$2
         if [ ! -d "$DUMP_STATE_DIRECTORY" ]; then
            print_v e "Dump state directory '$DUMP_STATE_DIRECTORY' doesn't exist!"
            exit 1
         fi
         shift;shift
      ;;
      -d|--debug)
         DEBUG=1
         VERBOSE=1
         shift
      ;;
      -h|--help)
         print_usage
         exit 1
         shift
      ;;
      -v|--verbose)
         VERBOSE=1
         shift
      ;;
      -V|--version)
         echo "$APP_NAME version $VERSION"
         shift
         exit 0
      ;;
      -S|--stdout)
         SYSTEMD_JOURNAL=1
         shift
      ;;
      -H|--housekeeping)
         CLEANING=0
         shift
      ;;
      -l|--list-backups)
        LIST_BACKUPS=yes
        shift
      ;;
      -R|--restore)
        RESTORE=yes
        shift
      ;;
      --as-copy)
        RESTORE_AS_COPY=yes
        shift
      ;;
    -- ) shift; break ;;
    * ) break ;;
  esac
done

dependencies_check
[ $? -ne 0 ] && exit 3

if [ ! -d $BACKUP_DIRECTORY ]; then
   print_v e "The backupdestination ($BACKUP_DIRECTORY) is not available"
   exit 1
fi

if [ ! -z ${CLEANING+x} ]; then
   print_v i "Clean-up of old backupsets requested"
   clean_backupsets
   print_v i "Clean-up finished"
   exit $_ret
fi

if [ ! -z ${LIST_BACKUPS+x} ]; then
   _ret=0
   if [ -z "$@" ];then
      _ret=1
      print_usage
   fi
   for i in $@;do
      list_backups $i
   done
   exit $_ret
fi

if [ ! -z ${RESTORE+x} ]; then
   restore_domain $1
   exit $_ret
fi

# Parameters validation
if [ ! -z ${CONSOLIDATION+x} ]; then
    if [ $CONSOLIDATION -eq 1 ]; then
    if [ ! -z ${QUIESCE+x} ] && [ $QUIESCE -eq 1 ]; then
        print_usage "consolidation (-c | -C) and quiesce (-q) are not compatible"
        exit 1
    fi
    if [ ! -z ${DUMP_STATE+x} ] && [ $DUMP_STATE -eq 1 ]; then
        print_usage \
            "consolidation (-c | -C) and dump state (-s) are not compatible"
        exit 1
    fi
    if [ $CONSOLIDATION_SET -eq 0 ]; then
        if check_version "$(qemu_version)" '2.1.0' && \
            check_version "$(libvirt_version)" '1.2.9'; then
            CONSOLIDATION_METHOD="blockcommit"
            CONSOLIDATION_FLAGS=(--wait --pivot --active)
        fi
    fi
    fi
fi

if [ ! -z ${DUMP_STATE+x} ] && [ $DUMP_STATE -eq 1 ]; then
   if [ $QUIESCE -eq 1 ]; then
      print_usage "dump state (-s) and quiesce (-q) are not compatible"
      exit 1
   fi
fi

rm -f /tmp/fi-backup*
DOMAIN_NAME="$@"
if [ -z "$DOMAIN_NAME" ]; then
   print_usage
   exit 2
fi

DOMAINS_RUNNING=
DOMAINS_NOTRUNNING=
if [ "$DOMAIN_NAME" == "all" ]; then
   DOMAINS_RUNNING=$($VIRSH -q -r list --state-running | awk '{print $2;}')
   DOMAINS_NOTRUNNING=$($VIRSH -q -r list --all --state-shutoff --state-paused | awk '{print $2;}')
else
   for THIS_DOMAIN in $DOMAIN_NAME; do
     DOMAIN_STATE=$($VIRSH -q domstate "$THIS_DOMAIN")
     if [ "$DOMAIN_STATE" == running ]; then
       DOMAINS_RUNNING="$DOMAINS_RUNNING $THIS_DOMAIN"
     else
       DOMAINS_NOTRUNNING="$DOMAINS_NOTRUNNING $THIS_DOMAIN"
     fi
   done
fi
DOMAINS_RUNNING=${DOMAINS_RUNNING//$'\n'/' '}
DOMAINS_NOTRUNNING=${DOMAINS_NOTRUNNING//$'\n'/' '}
print_v d "Domains RUNNING to process: $DOMAINS_RUNNING"
print_v d "Domains NOTRUNNING to process: $DOMAINS_NOTRUNNING"

for DOMAIN in $DOMAINS_RUNNING; do
   stamp=$(date +%Y-%m-%d_%H:%M:%S)
   print_v i "Processing domain '$DOMAIN'"
   if [ ! -d $BACKUP_DIRECTORY/$DOMAIN ]; then
      print_v i "Creating $BACKUP_DIRECTORY/$DOMAIN"
      mkdir -p $BACKUP_DIRECTORY/$DOMAIN
      chmod 666 $BACKUP_DIRECTORY/$DOMAIN  
   fi
   BACKUP_DIRECTORY_BASE=$BACKUP_DIRECTORY
   BACKUP_DIRECTORY="$BACKUP_DIRECTORY/$DOMAIN"
   _ret=0
   if [ $SNAPSHOT -eq 1 ]; then
      try_lock "$DOMAIN"
      if [ $? -eq 0 ]; then
         print_v d "Backupdestination for '$DOMAIN': $BACKUP_DIRECTORY"
         if [ -e $BACKUP_DIRECTORY/.backuptype ] && [ $(cat $BACKUP_DIRECTORY/.backuptype) == "offline" ];then
            print_v i "Start a new backupset because the last backup was 'offline'"
            move_backupset $DOMAIN $BACKUP_DIRECTORY
         fi
         $VIRSH dumpxml $DOMAIN > /tmp/fi-backup_$DOMAIN-$stamp.xml
         snapshot_domain "$DOMAIN"
         _ret=$?
         unlock "$DOMAIN"
         if [ $_ret -eq 0 ];then
            print_v v "Dump config of $DOMAIN to backupdestination"
            mv /tmp/fi-backup_$DOMAIN-$stamp.xml $BACKUP_DIRECTORY/$DOMAIN-$stamp.xml
         fi
      else
         print_v e "Another instance of $0 is already running on '$DOMAIN'! Skipping backup of '$DOMAIN'"
      fi
   fi


   if [ $_ret -eq 0 ] && [ ! -z ${CONSOLIDATION+x} ] && [ $CONSOLIDATION -eq 1 ]; then
      try_lock "$DOMAIN"
      if [ $? -eq 0 ]; then
         consolidate_domain "$DOMAIN"
         _ret=$?
         unlock "$DOMAIN"
         move_backupset $DOMAIN $BACKUP_DIRECTORY
      else
         print_v e "Another instance of $0 is already running on '$DOMAIN'! Skipping consolidation of '$DOMAIN'"
      fi
   fi
   print_v i "Domain '$DOMAIN' done"
   BACKUP_DIRECTORY=$BACKUP_DIRECTORY_BASE
done

for DOMAIN in $DOMAINS_NOTRUNNING; do
   _ret=0
   print_v i "Processing domain '$DOMAIN'"
   if [ ! -d $BACKUP_DIRECTORY/$DOMAIN ]; then
      print_v i "Creating $BACKUP_DIRECTORY/$DOMAIN"
      mkdir -p $BACKUP_DIRECTORY/$DOMAIN
      chmod 666 $BACKUP_DIRECTORY/$DOMAIN  
   fi
   BACKUP_DIRECTORY_BASE=$BACKUP_DIRECTORY
   BACKUP_DIRECTORY="$BACKUP_DIRECTORY/$DOMAIN"
   declare -a all_backing_files=()
   if [ "$BACKUP_DIRECTORY" == "" ]; then
         print_v e "-b flag (directory) required for backing up the shut-off domain '$DOMAIN'"
         print_v e "Skipping backup of '$DOMAIN'"
         _ret=1
   fi
   if [ $_ret -eq 0 ] && [ ! -z ${CONSOLIDATION+x} ] && [ $CONSOLIDATION -eq 1 ]; then
      print_v i "Skip consolidation of '$DOMAIN' because it is not running"
      continue
   fi

   if [ $_ret -eq 0 ]; then
      try_lock "$DOMAIN"
      _ret=$?
      if [ $_ret -ne 0 ]; then
         print_v e "Another instance of $0 is already running on '$DOMAIN'! Skipping backup of '$DOMAIN'"
      fi
   fi

   print_v d "Backupdestination for '$DOMAIN': '$BACKUP_DIRECTORY'"
   print_v i "Domain '$DOMAIN' is not in a running state"
   if [ $_ret -eq 0 ]; then
      get_block_devices "$DOMAIN" block_devices
      if [ -e $BACKUP_DIRECTORY/.backuptype ] && [ $(cat $BACKUP_DIRECTORY/.backuptype) == "online" ];then
         print_v i "Start a new backupset because the last backup was 'online'"
         move_backupset $DOMAIN $BACKUP_DIRECTORY
      fi
      for ((i = 0; i < ${#block_devices[@]}; i++)); do
         if [ ! -e $BACKUP_DIRECTORY/$(basename ${block_devices[$i]}) ]; then
            continue
         fi
         if [ $(stat -c %Y ${block_devices[$i]} 2>/dev/null) -ne $(stat -c %Y $BACKUP_DIRECTORY/$(basename ${block_devices[$i]}) 2>/dev/null) ]; then
            print_v i "A blockdevice of the not running domain '$DOMAIN' has been changed since the last backup; starting a new backupset"
            move_backupset $DOMAIN $BACKUP_DIRECTORY
            break
         fi
      done
      for ((i = 0; i < ${#block_devices[@]}; i++)); do
         backing_file=""
         block_device="${block_devices[$i]}"
         print_v d "Backing up the current blockdevice '$block_device'"
         cp -aup "$block_device" "$BACKUP_DIRECTORY"/ || print_v e "Unable to backup '$block_device'"
         
         get_backing_file "$block_device" backing_file
         j=0
         all_backing_files[$j]=$backing_file
         while [ -n "$backing_file" ]; do
            ((j++))
            all_backing_files[$j]=$backing_file
            print_v d "Parent block device: '$backing_file'"
            #In theory snapshots are unchanged so we can use one time cp instead of rsync
            print_v d "Backing up '$backing_file'"
            cp -aup "$backing_file" "$BACKUP_DIRECTORY"/ || print_v e "Unable to backup '$backing_file'"
            #get next backing file if it exists
            get_backing_file "$backing_file" parent_backing_file
            print_v d "Next file in backing file chain: '$parent_backing_file'"
            backing_file="$parent_backing_file"
         done
      done
      _ret=$?
      print_v v "Dump config of '$DOMAIN' to backupdestination"
      $VIRSH dumpxml $DOMAIN > $BACKUP_DIRECTORY/$DOMAIN-$(date +%Y-%m-%d_%H:%M:%S).xml
      unlock "$DOMAIN"
      (echo "offline" > $BACKUP_DIRECTORY/.backuptype) 2>/dev/null
   fi
   print_v i "Domain '$DOMAIN' done"
   BACKUP_DIRECTORY=$BACKUP_DIRECTORY_BASE
done

exit $_ret

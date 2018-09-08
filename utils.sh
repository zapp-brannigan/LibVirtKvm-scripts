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
function print_v() {
   local level=$1
   ts=$(date +%Y-%m-%d_%H:%M:%S)
   case $level in
      v) # Verbose
      if [ $VERBOSE -eq 1 ]; then
         if [ $SYSTEMD_JOURNAL -eq 0 ]; then
            echo -e "[VER] ${*:2}" | $SYSTEMD_CAT -t $APP_NAME
         else 
            echo -e "$ts [VER] ${*:2}"
         fi
      fi
      ;;
      d) # Debug
      if [ $DEBUG -eq 1 ]; then
         if [ $SYSTEMD_JOURNAL -eq 0 ]; then
            echo -e "[DEB] ${*:2}" | $SYSTEMD_CAT -t $APP_NAME -p debug
         else
            echo -e "$ts [DEB] ${*:2}"
         fi
      fi
      ;;
      e) # Error
      if [ $SYSTEMD_JOURNAL -eq 0 ]; then
        echo -e "[ERR] ${*:2}" | $SYSTEMD_CAT -t $APP_NAME -p err
      else
        echo -e "$ts [ERR] ${*:2}"
      fi
      ;;
      w) # Warning
      if [ $SYSTEMD_JOURNAL -eq 0 ]; then
         echo -e "[WAR] ${*:2}" | $SYSTEMD_CAT -t $APP_NAME -p warning
      else
         echo -e "$ts [WAR] ${*:2}"
      fi
      ;;
      *) # Any other level
      if [ $SYSTEMD_JOURNAL -eq 0 ]; then
         echo -e "[INF] ${*:2}" | $SYSTEMD_CAT -t $APP_NAME
      else
         echo -e "$ts [INF] ${*:2}"
      fi
      ;;
   esac
}

function print_usage() {
   cat <<EOU
   $APP_NAME version $VERSION - Davide Guerri <davide.guerri@gmail.com>

   Usage:

   $0 [-c|-C] [-q|-s <directory>] [-h] [-d] [-v] [-V] [-S] [-b <directory>] [-m <method>] <domain name>|all
   $0 -H

   Options
      -b <directory>    Copy previous snapshot/base image to the specified <directory>
      -c                Consolidation only
      -C                Snapshot and consolidation
      -d                Debug
      -h                Print usage and exit
      -H                Remove old backupsets
      -m <method>       Consolidation method: blockcommit or blockpull
      -q                Use quiescence (qemu agent must be installed in the domain)
      -s <directory>    Dump domain status in the specified directory
      -S                Log to stdout instead of systemd-journal
      -v                Verbose
      -V                Print version and exit

EOU
}

# Mutual exclusion management: only one instance of this script can be running
# at one time.
function try_lock() {
   local domain_name=$1

   exec 29>"/var/lock/$domain_name.fi-backup.lock"

   flock -n 29

   if [ $? -ne 0 ]; then
      return 1
   else
      return 0
   fi
}

function unlock() {
   local domain_name=$1

   rm "/var/lock/$domain_name.fi-backup.lock"
   exec 29>&-
}

# return 0 if program version is equal or greater than check version
function check_version()
{
    local version=$1 check=$2
    local winner=

    winner=$(echo -e "$version\n$check" | sed '/^$/d' | sort -Vr | head -1)
    [[ "$winner" = "$version" ]] && return 0
    return 1
}

# Function: get_block_devices()
# Return the list of block devices of a domain. This function correctly
# handles paths with spaces.
#
# Input:    Domain name
# Output:   An array containing a block device list
# Return:   0 on success, non 0 otherwise
function get_block_devices() {
   local domain_name=$1 return_var=$2
   local _ret=

   eval "$return_var=()"

   while IFS= read -r file; do
      eval "$return_var+=('$file')"
   done < <($VIRSH -q -r domblklist "$domain_name" --details|awk \
      '"disk"==$2 {$1=$2=$3=""; print $0}'|sed 's/^[ \t]*//')

   return 0
}

# Function: get_snapshot_chain()
# Return an array of all backing files
#
# Input:    Block Device
# Output:   An array containing a backing file list
# Return:   0 on success, non 0 otherwise
function get_snapshot_chain() {
   local endmost_child=$1 return_var=$2
   local _parent_backing_file=
   local _backing_file=
   local i=0
   local _ret=

   eval "$return_var[$i]=\"$endmost_child\""

   _ret=1

   get_backing_file "$endmost_child" _parent_backing_file
   while [ -n "$_parent_backing_file" ]; do
      ((i++))
      eval "$return_var[$i]=\"$_parent_backing_file\""
      #get next backing file if it exists
      _backing_file="$_parent_backing_file"
      get_backing_file "$_backing_file" _parent_backing_file
      #print_v d "Next file in backing file chain: '$_parent_backing_file'"
      _ret=0
   done 

   return $_ret
}
# Function: get_backing_file()
# Return the immediate parent of a qcow2 image file (i.e. the backing file)
#
# Input:    qcow2 image file name
# Output:   A backing file name
# Return:   0 on success, non 0 otherwise
function get_backing_file() {
   local file_name=$1 return_var=$2
   local _ret=
   local _backing_file=

   _backing_file=$($QEMU_IMG info "${QEMU_IMG_INFO_FLAGS[@]}" "$file_name" | \
      awk '/^backing file: / {$1=$2=""; print $0}'|sed 's/^[ \t]*//')
   _ret=$?

   eval "$return_var=\"$_backing_file\""

   return $_ret
}

# Function: dump_state()
# Dump a domain state, pausing the domain right afterwards
#
# Input:    a domain name
# Input:    a timestamp (this will be added to the file name)
# Return:   0 on success, non 0 otherwise
function dump_state() {
   local domain_name=$1
   local timestamp=$2

   local _ret=
   local _timeout=

   local _dump_state_filename="$DUMP_STATE_DIRECTORY/$domain_name.statefile-$timestamp.gz"

   local output=

   output=$($VIRSH qemu-monitor-command "$domain_name" '{"execute": "migrate", "arguments": {"uri": "exec:gzip -c > ' "'$_dump_state_filename'" '"}}' 2>&1)
   if [ $? -ne 0 ]; then
      print_v e "Failed to dump domain state: '$output'"
      return 1
   fi

   _timeout=5
   print_v d "Waiting for dump file '$_dump_state_filename' to be created"
   while [ ! -f "$_dump_state_filename" ]; do
      _timeout=$((_timeout - 1))
      if [ "$_timeout" -eq 0 ]; then
         print_v e "Timeout while waiting for dump file to be created"
         return 4
      fi
      sleep 1
      print_v d "Still waiting for dump file '$_dump_state_filename' to be created ($_timeout)"
   done
   print_v d "Dump file '$_dump_state_filename' created"

   if [ ! -f "$_dump_state_filename" ]; then
      print_v e "Dump file not created ('$_dump_state_filename'), something went wrong! ('$output' ?)"
      return 1
   fi

   _timeout="$DUMP_STATE_TIMEOUT"
   print_v d "Waiting for '$domain_name' to be paused"
   while true; do
      output=$(virsh domstate "$domain_name")
      if [ $? -ne 0 ]; then
         print_v e "Failed to check domain state"
         return 2
      fi
      if [ "$output" == "paused" ]; then
         print_v d "Domain paused!"
         break
      fi
      if [ "$_timeout" -eq 0 ]; then
         print_v e "Timeout while waiting for VM to pause: '$output'"
         return 3
      fi
      print_v d "Still waiting for '$domain_name' to be paused ($_timeout)"
      sleep 1
      _timeout=$((_timeout - 1))
   done

   return 0
}

# Function: snapshot_domain()
# Take a snapshot of all block devices of a domain
#
# Input:    Domain name
# Return:   0 on success, non 0 otherwise
function snapshot_domain() {
   local domain_name=$1

   local _ret=0
   local backing_file=
   local block_device=
   local block_devices=
   local extra_args=
   local command_output=
   local new_backing_file=
   local parent_backing_file=

   local timestamp=
   local resume_vm=0

   timestamp=$(date "+%Y%m%d-%H%M%S")

   print_v d "Snapshot for domain '$domain_name' requested"
   print_v d "Using timestamp '$timestamp'"

   # Dump VM state
   if [ ! -z ${DUMP_STATE+x} ] && [ "$DUMP_STATE" -eq 1 ]; then
      print_v v "Dumping domain state"
      dump_state "$domain_name" "$timestamp"
      if [ $? -ne 0 ]; then
         print_v e \
         "Domain state dump failed!"
         return 1
      else
         resume_vm=1
         # Should something go wrong, resume the domain
         trap 'virsh resume "$domain_name" >/dev/null 2>&1' SIGINT SIGTERM
      fi
   fi

   # Create an external snapshot for each block device
   print_v d "Snapshotting block devices for '$domain_name' using suffix '$SNAPSHOT_PREFIX-$timestamp'"

   if [ ! -z ${QUIESCE+x} ] && [ $QUIESCE -eq 1 ]; then
      print_v d "Quiesce requested"
      extra_args="--quiesce"
   fi

   command_output=$($VIRSH -q snapshot-create-as "$domain_name" \
      "$SNAPSHOT_PREFIX-$timestamp" --no-metadata --disk-only --atomic \
      $extra_args 2>&1)
   if [ $? -eq 0 ]; then
      print_v v "Snapshot for block devices of '$domain_name' successful"

      if [ -n "$BACKUP_DIRECTORY" ] && [ ! -d "$BACKUP_DIRECTORY" ]; then
         print_v e "Backup directory '$BACKUP_DIRECTORY' doesn't exist"
         _ret=1
      elif [ -n "$BACKUP_DIRECTORY" ] && [ -d "$BACKUP_DIRECTORY" ]; then
         #make backup after snapshot
         get_block_devices "$domain_name" block_devices
         if [ $? -ne 0 ]; then
            print_v e "Error getting block device list for domain \
            '$domain_name'"
            _ret=1
         else
            for ((i = 0; i < ${#block_devices[@]}; i++)); do
               block_device="${block_devices[$i]}"
               #if this is the fist run, need entire chain to back up
               print_v d "Getting all backing files for: '$block_device'"
               local snapshot_chain=()
               get_snapshot_chain "$block_device" snapshot_chain
               #backup entire chain except the snapshot just made (0th element of chain)
               for ((j = 1; j < ${#snapshot_chain[@]} ; j++)); do
                  backing_file_base=$(basename "${snapshot_chain[$j]}")
                  new_backing_file="$BACKUP_DIRECTORY/$backing_file_base"
                  if [ -f $new_backing_file ] && [ $(stat -c %Y ${snapshot_chain[$j]} 2>/dev/null) -eq $(stat -c %Y $new_backing_file 2>/dev/null) ]; then
                     print_v d "'${snapshot_chain[$j]}' has already been backed up, skipping"
                     continue
                  fi
                  print_v v "Backing up '${snapshot_chain[$j]}'"
                  cp -au "${snapshot_chain[$j]}" "$new_backing_file"
               done
            done
         fi
      else
         print_v d "No backup directory specified"
      fi
   else
      print_v e "Snapshot for '$domain_name' failed!"
      print_v e "Reason: <$command_output>"
      _ret=1
   fi

   if [ "$resume_vm" -eq 1 ]; then
      print_v d "Resuming domain"
      virsh resume "$domain_name" >/dev/null 2>&1
      if [ $? -ne 0 ]; then
         print_v e "Problem resuming domain '$domain_name'"
         _ret=1
      else
         print_v v "Domain resumed"
         trap "" SIGINT SIGTERM
      fi
   fi
   return $_ret
}

# Function: consolidate_domain()
# Consolidate block devices for a domain
# !!! This function will delete all previous file in the backing file chain !!!
#
# Input:    Domain name
# Return:   0 on success, non 0 otherwise
function consolidate_domain() {
   local domain_name=$1

   local _ret=
   local backing_file=
   local command_output=
   local parent_backing_file=

   local dom_state=
   dom_state=$($VIRSH domstate "$domain_name" 2>&1)
   if [ "$dom_state" != "running" ]; then
      print_v e "Consolidation requires '$domain_name' to be running"
      return 1
   fi

   local block_devices=''
   get_block_devices "$domain_name" block_devices
   if [ $? -ne 0 ]; then
      print_v e "Error getting block device list for domain '$domain_name'"
      return 1
   fi

   print_v d "Consolidation of block devices for '$domain_name' requested"
   print_v d "Block devices to be consolidated: '${block_devices[*]}'"
   print_v d "Consolidation method: $CONSOLIDATION_METHOD"

   for ((i = 0; i < ${#block_devices[@]}; i++)); do
      block_device="${block_devices[$i]}"
      print_v d \
         "Consolidation of '$i' block device: '$block_device' for '$domain_name'"

      get_backing_file "$block_device" backing_file
      if [ -n "$backing_file" ]; then
         print_v d "Parent block device: '$backing_file'"
         snapshot_chain=()
         #get an array of the snapshot chain starting from last child and iterating backwards
         # e.g.    [0]     [1]      [2]     [3]
         #       snap3 <- snap2 <- snap1 <- orig
         #
         # blockcommit: orig -> snap1 -> snap2 -> snap3 [becomes] orig
         # blockpull:   orig -> snap1 -> snap2 -> snap3 [becomes] snap3
         #do this BEFORE consolidation so that we keep complete chain info
         get_snapshot_chain "$block_device" snapshot_chain

         # Consolidate the block device
         #echo "ABOUT TO RUN:" 
         #echo "$VIRSH -q $CONSOLIDATION_METHOD $domain_name $block_device ${CONSOLIDATION_FLAGS[*]}"
         command_output=$($VIRSH -q "$CONSOLIDATION_METHOD" "$domain_name" \
            "$block_device" "${CONSOLIDATION_FLAGS[@]}" 2>&1)
         if [ $? -eq 0 ]; then
            print_v v "Consolidation of block device '$block_device' for '$domain_name' successful"
         else
            print_v e "Error consolidating block device '$block_device' for '$domain_name':\n $command_output"
            return 1
         fi


         if [ "$CONSOLIDATION_METHOD" == "blockcommit" ]; then
            # --delete option for blockcommit doesn't work (tested on
            # LibVirt 1.2.16, QEMU 2.3.0), so we need to manually delete old
            # backing files.
            # blockcommit will pivot the block device file with the base one
            # (the one originally used) so we can delete all the files created
            # by this script, starting from "$block_device".
            #
            print_v d \
              "Not deleting last element of snapshot_chain (top parent) since consolidation method='blockcommit'"
            unset snapshot_chain[${#snapshot_chain[@]}-1]
         else
            print_v d \
               "Not deleting 0th element of snapshot_chain (last child) since consolidation method='blockpull'"
            snapshot_chain=("${snapshot_chain[@]:1}")
         fi
         #echo "Complete Chain=" ${snapshot_chain[@]}

         # Deletes all old block devices
         print_v v "Deleting old backing files for '$domain_name'"

         _ret=$?
         for ((j = 0; j < ${#snapshot_chain[@]}; j++)); do
           print_v v \
              "Deleting old backing file '${snapshot_chain[$j]}' for '$domain_name'"
           rm "${snapshot_chain[$j]}"
           if [ $? -ne 0 ]; then
              print_v w "Could not delete file '${snapshot_chain[$j]}'!"
              break
           fi
         done
      else
         print_v d "No backing file found for '$block_device'. Nothing to do."
      fi
   done

   return 0
}

function libvirt_version() {
    $VIRSH -v
}

function qemu_version() {
    $QEMU --version | awk '/^QEMU emulator version / { print $4 }'
}

function qemu_img_version() {
    $QEMU_IMG -h | awk '/qemu-img version / { print $3 }' | cut -d',' -f1
}


# Dependencies check
function dependencies_check() {
   local _ret=0
   local version=

   if [ ! -x "$VIRSH" ]; then
      print_v e "'$VIRSH' cannot be found or executed"
      _ret=1
   fi

   if [ ! -x "$QEMU_IMG" ]; then
      print_v e "'$QEMU_IMG' cannot be found or executed"
      _ret=1
   fi

   if [ ! -x "$QEMU" ]; then
      print_v e "'$QEMU' cannot be found or executed"
      _ret=1
   fi
   
   if [ ! -x "$SYSTEMD_CAT" ] && [ $SYSTEMD_JOURNAL -eq 0 ]; then
      echo -e "[ERR] '$SYSTEMD_CAT' cannot be found or executed; use the '-S' switch to use stdout instead of systemd-journal"
      _ret=1
   fi

   version=$(libvirt_version)
   if check_version "$version" '0.9.13'; then
      if check_version "$version" '4.6.1'; then
         print_v i "libVirt version '$version' support is experimental"
      else
         print_v d "libVirt version '$version' is supported"
      fi
   else
      print_v e "Unsupported libVirt version '$version'. Please use libVirt 0.9.13 or later"
      _ret=2
   fi

   version=$(qemu_img_version)
   if check_version "$version" '1.2.0'; then
      print_v d "$QEMU_IMG version '$version' is supported"
      if check_version "$version" '2.12.0'; then
	     QEMU_IMG_INFO_FLAGS=(--force-share)
         print_v d "$QEMU_IMG later than '2.12.0', using --force-share/-U mode"
      fi
   else
      print_v e "Unsupported $QEMU_IMG version '$version'. Please use 'qemu-img' 1.2.0 or later"
      _ret=2
   fi

   version=$(qemu_version)
   if check_version "$version" '1.2.0'; then
      print_v d "QEMU/KVM version '$version' is supported"
   else
      print_v e "Unsupported QEMU/KVM version '$version'. Please use QEMU/KVM 1.2.0 or later"
      _ret=2
   fi

   return $_ret
}

# Move backups to a safe place after consolidating snapshots. Next backup starts a new "backupchain".
function move_backupset {
   local ts=$(date +%Y-%m-%d_%H:%M:%S)
   local DOMAIN=$1
   local BACKUP_DIRECTORY=$2
   print_v v "Moving current backups of '$DOMAIN' to '$BACKUP_DIRECTORY/set_$ts'"
   mkdir $BACKUP_DIRECTORY/set_$ts
   chmod 666 $BACKUP_DIRECTORY/set_$ts
   find $BACKUP_DIRECTORY -maxdepth 1 -type f -exec mv {} $BACKUP_DIRECTORY/set_$ts \; > /dev/null 2>&1
}

# Delete backupset which are older than $RETENTION_DAYS, but keep at least $BACKUP_SETS_TO_KEEP set(s)
function clean_backupsets {
   _ret=0
   backed_up=($(find $BACKUP_DIRECTORY -maxdepth 1 -mindepth 1 -type d))
   for vm in ${backed_up[@]}; do
      all_sets=($(find $BACKUP_DIRECTORY/$(basename $vm) -maxdepth 1 -mindepth 1 -type d -name set_*))
      print_v v "Found ${#all_sets[@]} backupsets for '$(basename $vm)'"
      if [ ${#all_sets[@]} -le $BACKUP_SETS_TO_KEEP ]; then
         print_v v "Number of backupsets for '$(basename $vm)' is below/equal $BACKUP_SETS_TO_KEEP; not removing any backupsets"
         continue
      fi
      old_sets=($(find $BACKUP_DIRECTORY/$(basename $vm) -maxdepth 1 -mindepth 1 -type d -name set_* -mtime +$RETENTION_DAYS))
      if [ ${#old_sets[@]} -eq 0 ]; then
         print_v v "No suitable backupsets found (too young)"
      else
         for set in ${old_sets[@]};do
            print_v v "Deleting '$set'"
            rm -rf "$set" > /dev/null 2>&1
            if [ $? -ne 0 ]; then
               print_v e "Error removing '$set'"
               _ret=1
            fi
         done
      fi
   done
}

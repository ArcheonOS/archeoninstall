#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-only
#
# This file is part of Archeon-Live-ISO.
# This file is part of ArcheonInstall.
#
# Copyright (c) 2025 erffy
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://gnu.org/licenses>.

set -euo pipefail

header() {
  clear
  ascii "Archeon   Install"
  echo
}

select_disk() {
  local multi=0 include_all=0
  while getopts "ma" opt; do
    case "$opt" in
      m) multi=1 ;;
      a) include_all=1 ;;
    esac
  done

  mapfile -t rows < <(
    lsblk -d -p -o NAME,SIZE,MODEL,TYPE,RM,ROTA,TRAN |
    awk -v inc="$include_all" 'NR>1 {
      if (!inc && ($4=="loop" || $4=="rom")) next
      # Replace empty model/transport with "?"
      if ($3=="") $3="?"
      if ($7=="") $7="?"
      # Output tab-separated: PATH SIZE MODEL TYPE RM ROTA TRAN
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n",$1,$2,$3,$4,$5,$6,$7
    }'
  )

  if (( ${#rows[@]} == 0 )); then
    echo "No disks found."
    return 1
  fi

  local options=()
  local line path size model type rm rota tran tag
  for line in "${rows[@]}"; do
    IFS=$'\t' read -r path size model type rm rota tran <<< "$line"
    tag=""
    [[ "$rm" == "1" ]] && tag="$tag · removable"
    [[ "$rota" == "1" ]] && tag="$tag · hdd" || tag="$tag · ssd"
    [[ "$tran" != "?" ]] && tag="$tag · $tran"
    options+=( "$(printf "%-20s — %-8s · %s%s" "$path" "$size" "$model" "$tag")" )
  done

  local choice
  if (( multi )); then
    mapfile -t choice < <(printf '%s\n' "${options[@]}" | gum choose --no-limit --header "Select disk(s) (Space to mark, Enter to confirm)")
  else
    choice=$(printf '%s\n' "${options[@]}" | gum choose --header "Select a disk")
  fi

  # Cancel
  if (( multi )); then
    (( ${#choice[@]} == 0 )) && return 130
  else
    [[ -z "$choice" ]] && return 130
  fi

  if (( multi )); then
    local paths=()
    for c in "${choice[@]}"; do
      paths+=( "$(awk '{print $1}' <<< "$c")" )
    done
    printf '%s\n' "${paths[@]}"
  else
    awk '{print $1}' <<< "$choice"
  fi
}

select_partition() {
  local multi=0 device=""
  while getopts "m" opt; do
    case "$opt" in
      m) multi=1 ;;
    esac
  done
  shift $((OPTIND-1))
  device="$1"

  local filter=""
  [[ -n "$device" ]] && filter="$device"

  mapfile -t rows < <(
    lsblk -rno NAME,SIZE,FSTYPE,MOUNTPOINT,TYPE "$filter" |
    awk '$5=="part" {
      if ($3=="") $3="?"
      if ($4=="") $4="-"
      printf "/dev/%s\t%s\t%s\t%s\n",$1,$2,$3,$4
    }'
  )

  if (( ${#rows[@]} == 0 )); then
    echo "No partitions found."
    return 1
  fi

  local options=()
  local line name size fstype mnt
  for line in "${rows[@]}"; do
    IFS=$'\t' read -r name size fstype mnt <<< "$line"
    options+=( "$(printf "%-20s — %-8s · fs:%-7s · mnt:%s" "$name" "$size" "$fstype" "$mnt")" )
  done

  local choice
  if (( multi )); then
    mapfile -t choice < <(printf '%s\n' "${options[@]}" | gum choose --no-limit --header "Select partition(s)")
  else
    choice=$(printf '%s\n' "${options[@]}" | gum choose --header "Select a partition")
  fi

  if (( multi )); then
    (( ${#choice[@]} == 0 )) && return 130
  else
    [[ -z $choice ]] && return 130
  fi

  if (( multi )); then
    local parts=()
    for c in "${choice[@]}"; do
      parts+=( "$(awk '{print $1}' <<< "$c")" )
    done
    printf '%s\n' "${parts[@]}"
  else
    awk '{print $1}' <<< "$choice"
  fi
}

select_kb_layout() {
  local base="/usr/share/kbd/keymaps"

  mapfile -t files < <(find "$base" -type f \( -name "*.map" -o -name "*.map.gz" \))

  if (( ${#files[@]} == 0 )); then
    echo "No keyboard layouts found in $base."
    return 1
  fi

  local short_names=()
  local file
  for file in "${files[@]}"; do
    local basename_file=$(basename "$file")
    basename_file="${basename_file%.map.gz}"
    basename_file="${basename_file%.map}"
    short_names+=("$basename_file")
  done

  local choice=$(printf '%s\n' "${short_names[@]}" | fzf --prompt="Select keyboard layout: ")

  if [[ -z $choice ]]; then
    echo "Selection cancelled."
    return 130
  fi

  for file in "${files[@]}"; do
    local basename_file=$(basename "$file")
    basename_file="${basename_file%.map.gz}"
    basename_file="${basename_file%.map}"
    if [[ "$basename_file" == "$choice" ]]; then
      echo "$file"
      return 0
    fi
  done

  echo "Error: Selected layout not found."
  return 1
}

select_mountpoints() {
  local disk="$1"
  local root_target="/mnt"

  if [[ -z "$disk" ]]; then
    echo "No disk specified."
    return 1
  fi

  mapfile -t parts < <(lsblk -ln -o NAME,TYPE $disk | awk '$2=="part"{print "/dev/"$1}')

  if (( ${#parts[@]} == 0 )); then
    echo "No partitions found on $disk."
    return 1
  fi

  local root_part=$(printf '%s\n' "${parts[@]}" | fzf --header="Select ROOT (/) partition")
  if [[ -z "$root_part" ]]; then
    echo "Root partition not selected!"
    return 1
  fi

  declare -A mounts
  mounts["/"]="$root_part"

  local remaining_parts=()
  for p in "${parts[@]}"; do
    [[ "$p" == "$root_part" ]] && continue
    remaining_parts+=("$p")
  done

  local mountpoints=("/boot" "/home" "/var" "/srv" "/opt" "/mnt" "Skip")

  for part in "${remaining_parts[@]}"; do
    local mp=$(printf '%s\n' "${mountpoints[@]}" | fzf --header="Select mountpoint for $part (or Skip)")
    [[ "$mp" == "Skip" || -z "$mp" ]] && continue
    mounts["$mp"]="$part"
  done

  echo
  echo "Mount configuration:"
  for mp in "${!mounts[@]}"; do
    printf "  %-10s -> %s\n" "$mp" "${mounts[$mp]}"
  done

  echo
  echo "Mounting..."
  mount "${mounts[/]}" "$root_target"

  for mp in "${!mounts[@]}"; do
    [[ "$mp" == "/" ]] && continue
    mkdir -p "$root_target$mp"
    mount "${mounts[$mp]}" "$root_target$mp"
  done

  echo "All partitions mounted under $root_target."
}

generate_fstab() {
  local root_target="$1"

  genfstab -U $root_target > $root_target/etc/fstab

  echo "fstab generated at $root_target."
}

partition_disk() {
  local disk="$1"

  if [[ -z $disk ]]; then
    echo "No disk specified."
    return 1
  fi

  echo "Disk: $disk will be partitioned. All data may be lost!"
  gum confirm "Are you sure you want to continue?" || return 1

  local part_type=$(printf "primary\nlogical" | gum choose --header "Select partition type")

  if [[ -z "$part_type" ]]; then
    echo "Partition type selection cancelled."
    return 1
  fi

  local size=$(gum input --header "Enter partition size (e.g., 20G, 500M):")

  if [[ -z $size ]]; then
    echo "Partition size not provided."
    return 1
  fi

  echo "Creating $part_type partition of size $size on $disk..."

  parted -s $disk mkpart $part_type 0% $size

  echo "Partition created on $disk."
}

# Keep track of mounted points to prevent double mounts
declare -A MOUNTED_POINTS

partition_disk_multi() {
    local disks=("$@")
    if (( ${#disks[@]} == 0 )); then
        echo "Usage: partition_disk_multi /dev/sdX /dev/sdY ..." >&2
        return 1
    fi

    for disk in "${disks[@]}"; do
        gum style --border normal --margin "1" --padding "1 2" \
            "Starting to process $(gum style --bold --foreground 212 "$disk"). All data may be lost!"

        gum confirm "Continue with $disk?" || continue

        if ! parted -s "$disk" print >/dev/null 2>&1; then
            if gum confirm "Disk has no label. Create new GPT label on $disk?"; then
                parted -s "$disk" mklabel gpt
            else
                echo "Skipping disk $disk."
                continue
            fi
        fi

        mapfile -t partitions < <(lsblk -pln -o NAME,TYPE "$disk" | awk '$2=="part"{print $1}')
        if (( ${#partitions[@]} > 0 )); then
            echo "Existing partitions found on $disk:"
            printf '  %s\n' "${partitions[@]}"

            if gum confirm "Do you want to format any of these existing partitions?"; then
                for p in "${partitions[@]}"; do
                    if gum confirm "Create a new filesystem on $p?"; then
                        local fs
                        fs=$(select_filesystem "$p")
                        [[ -n $fs ]] && format_partition "$p" "$fs"
                    fi
                done
            fi
        fi

        while gum confirm "Create a new partition on $disk?"; do
            free_space_start_b=$(parted -sm "$disk" unit B print free | awk -F: '/free/ {print $2}' | tail -n1 | tr -d 'B')
            
            if [[ -z "$free_space_start_b" ]]; then
                 echo "Could not determine free space on $disk. Cannot create new partitions."
                 break
            fi

            disk_size_b=$(blockdev --getsize64 "$disk")
            free_bytes=$((disk_size_b - free_space_start_b))
            free_mib=$((free_bytes / 1024 / 1024))

            if (( free_bytes < 1048576 )); then
                echo "No significant free space left on $disk. Cannot create new partitions."
                break
            fi
            
            echo "Available space: $free_mib MiB"

            part_name=$(gum input --placeholder "data" --header "Enter a name for the new partition")
            [[ -z "$part_name" ]] && part_name="Linux-Data"

            size_input=$(gum input --placeholder "e.g., 2048 or 'remaining'" --header "Enter partition size in MiB (or 'remaining')")
            [[ -z "$size_input" ]] && continue

            mapfile -t partitions_before < <(lsblk -pln -o NAME "$disk")

            if [[ "$size_input" == "remaining" ]]; then
                parted -s -a optimal "$disk" mkpart "$part_name" "${free_space_start_b}B" 100%
            else
                if ! [[ "$size_input" =~ ^[0-9]+$ ]]; then
                    echo "Invalid size. Please enter a number." >&2
                    continue
                fi
                size_bytes=$((size_input * 1024 * 1024))
                end_bytes=$((free_space_start_b + size_bytes))
                parted -s -a optimal "$disk" mkpart "$part_name" "${free_space_start_b}B" "${end_bytes}B"
            fi
            
            if [[ $? -ne 0 ]]; then
                echo "Error: parted failed to create the partition." >&2
                continue
            fi

            echo "Forcing kernel to re-read partition table..."
            partprobe "$disk"
            sleep 1

            mapfile -t partitions_after < <(lsblk -pln -o NAME "$disk")
            new_part_dev=$(comm -13 <(printf "%s\n" "${partitions_before[@]}") <(printf "%s\n" "${partitions_after[@]}"))

            if [[ -z "$new_part_dev" ]]; then
                echo "Error: Could not detect the newly created partition device." >&2
                break
            fi

            echo "Successfully created partition: $new_part_dev"
            
            if gum confirm "Format the new partition $new_part_dev?"; then
                fs=$(select_filesystem "$new_part_dev")
                [[ -n $fs ]] && format_partition "$new_part_dev" "$fs"
            fi
        done
    done

    gum style --bold --foreground 205 "All operations complete."
}

select_filesystem() {
    local part="$1"
    local fs_types=("ext4" "ext3" "ext2" "btrfs" "xfs" "vfat" "ntfs")
    local fs
    fs=$(printf '%s\n' "${fs_types[@]}" | gum choose --header "Select filesystem type for $part")
    echo "$fs"
}

format_partition() {
    local part="$1"
    local fs="$2"

    [[ -z $part || -z $fs ]] && return 1

    gum confirm "Are you sure you want to format $part as $fs? This will destroy all data!" && {
        mkfs -t "$fs" "$part"
        echo "$part formatted as $fs"
    } || echo "Skipped formatting $part"
}

mount_partition() {
    local part="$1"
    local target="$2"

    if [[ -z $part || -z $target ]]; then
        echo "Missing partition or mount point."
        return 1
    fi

    mkdir -p "$target"

    # Skip if already mounted or already in MOUNTED_POINTS
    if grep -qs "$target" /proc/mounts || [[ -n ${MOUNTED_POINTS[$target]} ]]; then
        echo "$target is already mounted. Skipping $part."
        return 0
    fi

    mount "$part" "$target"
    MOUNTED_POINTS[$target]=1
    echo "Mounted $part to $target"
}

pacstrap_install() {
  local mount_point="$1"

  if [[ -z "$mount_point" ]]; then
    echo "No mount point specified."
    return 1
  fi

  if [[ ! -d "$mount_point" ]]; then
    echo "Mount point $mount_point does not exist."
    return 1
  fi

  local packages=("base" "base-devel" "linux-firmware" "sudo" "vim" "nano")

  mapfile -t selected_packages < <(printf '%s\n' "${packages[@]}" | gum choose --no-limit --header "Select packages to install")

  if (( ${#selected_packages[@]} == 0 )); then
    echo "No packages selected. Skipping pacstrap."
    return 0
  fi

  echo "The following packages will be installed on $mount_point:"
  printf '%s\n' "${selected_packages[@]}"

  gum confirm "Do you want to continue with pacstrap?" || { echo "Pacstrap cancelled."; return 0; }

  pacstrap -K "$mount_point" "${selected_packages[@]}"
  echo "Pacstrap completed on $mount_point."
}
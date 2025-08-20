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

set_root_password() {
    log_step "setting root password"
    passwd
    echo "Root password set."
}

add_users() {
    while true; do
        local username=$(gum input --placeholder "Enter username to create (leave empty to finish)")
        [[ -z $username ]] && break

        if id $username &>/dev/null; then
            echo "User $username already exists. Skipping."
            continue
        fi

        log_step "creating user $username"
        useradd -mG wheel $username
        passwd $username

        if gum confirm "Add $username to sudoers?"; then
            sed -i 's/^# %wheel ALL=(ALL) ALL/%wheel ALL=(ALL) ALL/' /etc/sudoers
            echo "$username added to sudoers"
        fi

        echo
        gum confirm "Do you want to add another user?" || break
    done
}

set_hostname() {
    local hostname
    hostname=$(gum input --placeholder "Enter hostname")
    [[ -z "$hostname" ]] && return

    log_step "setting hostname"
    echo "$hostname" > /etc/hostname
    cat <<EOF >/etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $hostname
EOF
    echo "Hostname set."
}

configure_locales() {
    local file="/etc/locale.gen"

    mapfile -t locales < <(grep -E '^[[:space:]]*#?[a-zA-Z0-9_]+\.?[a-zA-Z0-9_-]*\s+UTF-8' "$file" | sed 's/^[[:space:]]*//')

    mapfile -t selected < <(printf '%s\n' "${locales[@]}" | fzf --multi --header "Select locales")

    for loc in "${selected[@]}"; do
        sed -i "s|^\s*#\?\s*$loc|$loc|" "$file"
    done

    locale-gen >/dev/null
    echo "Locales configured: ${selected[*]}"
}

set_timezone() {
    local TZ
    TZ=$(gum input --placeholder "Enter timezone (leave empty for auto detect)")
    [[ -z "$TZ" ]] && TZ=$(curl -s ipinfo.io/timezone)
    [[ -z "$TZ" ]] && { echo "Cannot detect timezone"; return; }

    ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
    hwclock --systohc
    echo "Timezone set to $TZ"
}

install_bootloader() {
    local bootloaders=("grub" "systemd-boot" "refind" "none")
    local selected
    selected=$(printf '%s\n' "${bootloaders[@]}" | gum choose --header "Select bootloader")
    [[ -z "$selected" || "$selected" == "none" ]] && return

    case "$selected" in
        grub)         install_grub ;;
        systemd-boot) install_systemd_boot ;;
        refind)       install_refind ;;
    esac
}

install_grub() {
    pacman -S --noconfirm grub
    local disk
    disk=$(select_disk_for_bootloader)
    [[ -n "$disk" ]] && grub-install --target=i386-pc "$disk"
    grub-mkconfig -o /boot/grub/grub.cfg
    log_success "GRUB installed and configured"
}

install_systemd_boot() {
    log_step "Installing systemd-boot"

    # Ensure /boot exists
    mkdir -p /boot

    # Attempt to install systemd-boot
    if ! bootctl install; then
        log_warning "systemd-boot installation failed (maybe in chroot). Continuing..."
    fi

    # Loader config
    mkdir -p /boot/loader
    cat <<EOF >/boot/loader/loader.conf
default arch.conf
timeout 5
EOF

    # Detect root partition dynamically
    local root_part
    root_part=$(findmnt / -no SOURCE 2>/dev/null || true)
    [[ -z "$root_part" ]] && { log_warning "Cannot detect root partition"; return; }
    local partuuid
    partuuid=$(blkid -s PARTUUID -o value "$root_part")

    # Detect kernel/initramfs
    local kernel initramfs
    kernel=$(ls /boot/vmlinuz-* 2>/dev/null | head -n1 || true)
    initramfs=$(ls /boot/initramfs-* 2>/dev/null | head -n1 || true)
    if [[ -z "$kernel" || -z "$initramfs" ]]; then
        log_warning "Kernel/initramfs not found, skipping entry creation"
        return
    fi

    mkdir -p /boot/loader/entries
    cat <<EOF >/boot/loader/entries/arch.conf
title   Arch Linux
linux   /$(basename "$kernel")
initrd  /$(basename "$initramfs")
options root=PARTUUID=$partuuid rw
EOF

    log_success "systemd-boot installed and default entry created"
}


install_refind() {
    pacman -S --noconfirm refind
    refind-install
    log_success "rEFInd installed and configured"
}

select_disk_for_bootloader() {
    mapfile -t disks < <(lsblk -d -p -o NAME,SIZE,MODEL | awk 'NR>1 {print $1}')
    [[ ${#disks[@]} -eq 0 ]] && return 1
    local choice
    choice=$(printf '%s\n' "${disks[@]}" | gum choose --header "Select disk for bootloader")
    echo "$choice"
}

install_microcode() {
    local vendor
    vendor=$(awk -F': ' '/vendor_id/ {print $2; exit}' /proc/cpuinfo)
    case "$vendor" in
        GenuineIntel) pacman -S --noconfirm intel-ucode ;;
        AuthenticAMD) pacman -S --noconfirm amd-ucode ;;
    esac
    echo "Microcode installed."
}

install_packages() {
    local old_opts="$-"
    set +e
    
    local input=$(gum input --placeholder "Enter packages to install (space separated)")
    [[ -z "$input" ]] && { log_note "No packages selected, skipping installation."; return; }

    IFS=' ' read -r -a selected_packages <<< "$input"

    local total=${#selected_packages[@]}
    local count=0

    log_info "Starting installation of ${total} packages: ${selected_packages[*]}"

    for pkg in "${selected_packages[@]}"; do
        [[ -z "$pkg" ]] && continue
        
        ((count++))
        local percent=$((count*100/total))

        pacman -Q "$pkg" >/dev/null 2>&1
        if [[ $? -eq 0 ]]; then
            log_note "$pkg is already installed ($count/$total, $percent%)"
            continue
        fi

        if gum spin --title "Installing $pkg ($count/$total, $percent%)..." -- \
            sudo pacman -Sy --noconfirm "$pkg" >/dev/null 2>&1; then
            log_success "Successfully installed $pkg"
        else
            log_warning "Failed to install $pkg, continuing..."
        fi
    done

    log_success "Package installation process completed ($count/$total packages processed)"
    
    [[ "$old_opts" == *e* ]] && set -e
}
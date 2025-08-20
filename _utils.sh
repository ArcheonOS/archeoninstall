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

check_root() {
    (( EUID == 0 )) && return 0

    local helpers=("sudo-rs" "sudo" "doas" "su")
    local cmd

    for cmd in "${helpers[@]}"; do
      command -v $cmd &>/dev/null && exec $cmd $0 $@
    done

    echo "This script requires root privileges but no helper found."
    exit 1
}

check_requirements() {
    local packages=("gum" "figlet" "fzf" "parted" "util-linux")
    local helpers=("yay" "paru" "trizen" "pacman")

    for package in "${packages[@]}"; do
        if pacman -Qi $package &>/dev/null; then
            continue
        fi

        local installed=false
        for helper in "${helpers[@]}"; do
            if pacman -Qi $helper &>/dev/null; then
                log_note "Installing '$package'"
                case "$helper" in
                    yay|paru|pacman) $helper -S --noconfirm --needed $package >/dev/null ;;
                    trizen)   $helper -S --noconfirm --needed --noedit $package >/dev/null ;;
                esac
                installed=true
                break
            fi
        done

        if ! pacman -Qi $package &>/dev/null; then
            log_error "Failed to install '$package'."
            exit 1
        fi
    done
}
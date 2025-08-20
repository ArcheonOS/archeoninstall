#!/usr/bin/env bash

# SPDX-License-Identifier: GPL-3.0-only
#
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

BASE_DIR="$(pwd)"

source $BASE_DIR/_log.sh
source $BASE_DIR/_utils.sh
source $BASE_DIR/_iutils.sh

# Run fix-keyring script to fix keyring issues, this is available on Archeon by default
if command -v fix-keyring &>/dev/null; then
    if [[ ! -f /tmp/keyring.lock ]]; then
        fix-keyring
        touch /tmp/keyring.lock
    fi
fi

check_root
check_requirements

header

selected_disk=$(select_disk)
root_target="/mnt"

partition_disk_multi $selected_disk
select_mountpoints $selected_disk
pacstrap_install $root_target
generate_fstab $root_target

mkdir -p $root_target/archeon
cp -r $BASE_DIR/* $root_target/archeon

chmod +x $root_target/archeon/*.sh

arch-chroot $root_target /archeon/install_chroot.sh

rm -rf $root_target/archeon

ascii "Installation     Completed"
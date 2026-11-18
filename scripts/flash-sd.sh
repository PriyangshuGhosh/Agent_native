#!/bin/bash
# Usage: sudo scripts/flash-sd.sh /dev/sdX [image]. Writes the Pi image, then grows root to fill the card.
set -eu
D=${1:?device}; IMG=${2:-build/debian-img/cua-agentos-pi5.img}
# Guard: only a removable USB disk under 64 GB, never the system disk.
[ -b "$D" ] && [ "$(cat /sys/block/${D#/dev/}/removable)" = 1 ] && [ "$(lsblk -dno TRAN "$D")" = usb ] &&
	[ "$(lsblk -bdno SIZE "$D")" -lt $((64 << 30)) ] || { echo "refusing $D: not a small removable USB disk" >&2; exit 1; }
for p in $(lsblk -lnpo NAME "$D" | tail -n +2); do umount "$p" 2>/dev/null || true; done
dd if="$IMG" of="$D" bs=4M conv=fsync status=progress
sync; partprobe "$D"; sleep 2
echo ', +' | sfdisk -q -N 2 --force "$D"   # partition 2 -> end of card; PARTUUID unchanged
partprobe "$D"; sleep 2
e2fsck -fy "${D}2" || [ $? -le 1 ]; resize2fs "${D}2"
sync; udevadm settle; lsblk -o NAME,SIZE,FSTYPE,LABEL "$D"
# A card that dropped off the bus mid-write shows no filesystem here (seen 2026-11-14): say so instead of looking done.
[ "$(lsblk -no FSTYPE "${D}2")" = ext4 ] && [ "$(lsblk -no FSTYPE "${D}1")" = vfat ] && echo "FLASH OK: $IMG on $D" ||
	{ echo "FLASH FAILED: $D has no readable filesystems; reseat the card and run this again" >&2; exit 1; }

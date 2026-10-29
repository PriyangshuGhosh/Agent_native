#!/bin/sh
# Build a Raspberry Pi 5 SD-card image, build/pi5/cua-agentos-pi5.img: the Cycle 06 system cross-built for aarch64 on
# Alpine's linux-rpi kernel. MBR with two partitions: p1 FAT32 boot (read by the Pi 5 EEPROM firmware: config.txt,
# cmdline.txt, kernel, initramfs, DTBs) and p2 the raw read-only SquashFS base (/dev/mmcblk0p2). As on the ISO, the
# kernel runs agent-init from the initramfs (rdinit=) and the OverlayFS upper is tmpfs, or an ext4 partition labelled
# agentos-data if one exists. No serial cable needed: telemetry goes to agentos.log on the FAT partition (plus stage1.log
# and dmesg.txt), and agent.hold stops without powering off; kernel messages go to HDMI. For the debug UART instead set
# console=ttyAMA10,115200 AGENT_TTY=/dev/ttyAMA10 in cmdline.txt (GPIO 14/15 USB-TTL: ttyAMA0). No root needed; it needs aarch64-linux-gnu-gcc, qemu-aarch64-static (only for busybox --list-full)
# and mtools on PATH.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=$ROOT/build/pi5
export SOURCE_DATE_EPOCH=1700000000
for t in aarch64-linux-gnu-gcc qemu-aarch64-static mcopy; do
	command -v "$t" >/dev/null || { echo "build-pi5-img: missing $t (apt install gcc-aarch64-linux-gnu qemu-user-static mtools)" >&2; exit 2; }
done

ARCH=aarch64 KERNEL=rpi CROSS=aarch64-linux-gnu- CROSS_RUN=qemu-aarch64-static BASE_FS=mmc ROOTFS_OUT=$D \
PACKAGES_DIR=$ROOT/rootfs/packages "$ROOT/scripts/build-rootfs-05.sh"

B=$D/boot
rm -rf "$B" && mkdir -p "$B"
cp -r "$D/vmlinuz" "$D/initramfs" "$D"/bcm2712*.dtb "$D/overlays" "$B/"
# uart0 (GPIO 14/15, ttyAMA0) is enabled too, so a USB-TTL adapter only needs AGENT_TTY/console switched in cmdline.txt;
# hdmi_force_hotplug keeps the firmware framebuffer (tty1) up even if the monitor is slow to answer; the KMS overlay is
# what gives the Pi 5 kernel an HDMI console at all.
cat >"$B/config.txt" <<'CFG'
arm_64bit=1
kernel=vmlinuz
initramfs initramfs followkernel
enable_uart=1
dtparam=uart0=on
hdmi_force_hotplug=1
dtoverlay=vc4-kms-v3d
CFG
echo 'rdinit=/usr/bin/agent-init console=tty1 AGENT_TTY=/mnt/boot/agentos.log agent.hold panic=0' >"$B/cmdline.txt"
find "$B" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +

BOOT_MB=256
SQ_MB=$((($(stat -c %s "$D/rootfs.squashfs") + 1048575) / 1048576))
IMG=$D/cua-agentos-pi5.img
rm -f "$D/boot.vfat" "$IMG"
mkfs.vfat -C -F 32 -n AGENTOS --invariant "$D/boot.vfat" $((BOOT_MB * 1024)) >/dev/null
MTOOLS_SKIP_CHECK=1 mcopy -s -m -i "$D/boot.vfat" "$B"/* ::/
truncate -s $(((1 + BOOT_MB + SQ_MB) * 1048576)) "$IMG"
sfdisk -q "$IMG" <<EOF
label: dos
label-id: 0x41474f53
start=2048, size=$((BOOT_MB * 2048)), type=c, bootable
start=$(((1 + BOOT_MB) * 2048)), size=$((SQ_MB * 2048)), type=83
EOF
dd if="$D/boot.vfat" of="$IMG" bs=1M seek=1 conv=notrunc status=none
dd if="$D/rootfs.squashfs" of="$IMG" bs=1M seek=$((1 + BOOT_MB)) conv=notrunc status=none
rm -rf "$B" "$D/boot.vfat"
sha256sum "$IMG"

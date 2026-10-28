#!/bin/sh
# Build Cycle 07: the Cycle 06 system as a BIOS-bootable ISO (ISOLINUX -> vmlinuz + initramfs; the initramfs mounts the
# CD and loop-mounts /rootfs.squashfs as the read-only base). Builds it twice from scratch into build/iso/run{1,2}.iso
# to prove reproducibility, then installs run1 as build/iso/cua-agentos.iso. No root needed.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=$ROOT/build/iso
SYSLINUX=syslinux-6.04_pre1-r19.apk
export SOURCE_DATE_EPOCH=1700000000
mkdir -p "$D"

# ISOLINUX binaries from Alpine's syslinux package (not installed on the host).
if [ ! -f "$D/syslinux/usr/share/syslinux/isolinux.bin" ]; then
	rm -rf "$D/syslinux" && mkdir -p "$D/syslinux"
	curl -sSf --connect-timeout 15 --max-time 60 -o "$D/syslinux/$SYSLINUX" \
		"${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}/v3.24/main/x86_64/$SYSLINUX"
	echo "8d48ed312febfca789740fab80cc07c7f380ce2cb629a0005ea92b049b81aad1  $D/syslinux/$SYSLINUX" | sha256sum -c --quiet
	tar -xzf "$D/syslinux/$SYSLINUX" -C "$D/syslinux" usr/share/syslinux/isolinux.bin usr/share/syslinux/ldlinux.c32 2>/dev/null
fi

for run in run1 run2; do
	S=$D/$run.tree
	rm -rf "$D/$run" "$S"
	ROOTFS_OUT=$D/$run BASE_FS=iso PACKAGES_DIR=$ROOT/rootfs/packages "$ROOT/scripts/build-rootfs-05.sh"
	mkdir -p "$S/isolinux" "$S/boot"
	cp "$D/syslinux/usr/share/syslinux/isolinux.bin" "$D/syslinux/usr/share/syslinux/ldlinux.c32" "$S/isolinux/"
	# agent.test_poweroff is left off: it makes agent-init power off before starting agentd (Cycle 02's gate);
	# the unattended run powers off on its own when agentd exits.
	cat >"$S/isolinux/isolinux.cfg" <<'CFG'
DEFAULT agentos
PROMPT 0
TIMEOUT 0
LABEL agentos
  KERNEL /boot/vmlinuz
  INITRD /boot/initramfs
  APPEND rdinit=/usr/bin/agent-init console=ttyS0 quiet loglevel=0 panic=0
CFG
	cp "$D/$run/vmlinuz" "$D/$run/initramfs" "$S/boot/"
	cp "$D/$run/rootfs.squashfs" "$S/"
	find "$S" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
	rm -f "$D/$run.iso"
	xorriso -as mkisofs -quiet -o "$D/$run.iso" -iso-level 3 -full-iso9660-filenames -r \
		-volid CUA_AGENTOS -preparer "" -publisher "" \
		-b isolinux/isolinux.bin -c isolinux/boot.cat -no-emul-boot -boot-load-size 4 -boot-info-table "$S"
	rm -rf "$S"
done
cp "$D/run1.iso" "$D/cua-agentos.iso"
sha256sum "$D/run1.iso" "$D/run2.iso"

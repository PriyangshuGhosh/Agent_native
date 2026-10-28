#!/bin/sh
# Build Cycle 06 into build/rootfs-06/{vmlinuz,initramfs,rootfs.squashfs}: the Cycle 05 image as a read-only SquashFS
# base under a tmpfs OverlayFS root, plus the capability packages agentd installs (rootfs/packages/).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ROOTFS_OUT=$ROOT/build/rootfs-06 BASE_FS=squashfs PACKAGES_DIR=$ROOT/rootfs/packages \
	exec "$ROOT/scripts/build-rootfs-05.sh"

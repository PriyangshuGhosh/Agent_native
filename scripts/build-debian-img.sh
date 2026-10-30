#!/bin/sh
# Debian base, step 3: a bootable CUA-AgentOS disk image, Debian 13 (trixie) + our packages, built without root
# (mmdebstrap --mode=unshare; needs mmdebstrap, uidmap, mtools, e2fsprogs >= 1.47.1, and for arm64 qemu-user-static
# plus aarch64-linux-gnu-gcc for the agentd .deb, e.g. `. build/cross/env.sh`).
#   ARCH=amd64 (default): build/debian-img/cua-agentos-amd64.img, GPT: ESP (systemd-boot, UEFI only) + ext4 root.
#   ARCH=arm64: build/debian-img/cua-agentos-pi5.img, MBR: FAT boot (Pi 5 EEPROM loader; Raspberry Pi kernel and Wi-Fi
#               firmware from archive.raspberrypi.com) + ext4 root.
# Both: the FAT partition is /boot/firmware, rootfs/debian/ is laid over the system, the screen shows the agent console
# in a cage kiosk (keyboard and mouse; `wifi` joins a network) and tty2 keeps a login. Root is locked unless
# ROOT_PASSWORD_HASH is set (from `openssl passwd -6`). The Gemini key is never in the image: copy gemini.env (or the
# bare key) onto the FAT partition and the first boot moves it to /etc/agentd/gemini.env.
set -eu
ARCH=${ARCH:-amd64}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
O=$ROOT/build/debian-img
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1700000000}
BOOT_MB=256
export ROOT_PASSWORD_HASH=${ROOT_PASSWORD_HASH:-} # read by the chroot hook from the environment: a hash contains $
RPI_KEY_FPR=CF8A1AF502A2AA2D763BAE7E82B129927FA3303E
mkdir -p "$O"
DEB=$(DEB_ARCH=$ARCH "$ROOT/scripts/build-deb.sh")

SOURCES="deb http://deb.debian.org/debian trixie main non-free-firmware
deb http://deb.debian.org/debian trixie-updates main non-free-firmware
deb http://security.debian.org/debian-security trixie-security main non-free-firmware"
PKGS=systemd-sysv,dbus,polkitd,libpam-systemd,network-manager,wpasupplicant,systemd-timesyncd,cage,foot,fonts-dejavu-core
PKGS=$PKGS,libgl1-mesa-dri,libegl-mesa0,curl,ca-certificates,login,passwd,less,initramfs-tools
KEYRINGS=--keyring=/usr/share/keyrings/debian-archive-keyring.gpg
case $ARCH in
amd64)
	IMG=$O/cua-agentos-amd64.img
	PKGS=$PKGS,linux-image-amd64,systemd-boot-efi
	ROOT_UUID=6e8c9b2a-1d7f-4c3e-9a51-0b2f7d4e8c11 BOOT_UUID=c12a7328-0000-4a6f-8e00-41474f530001
	ROOT_DEV=PARTUUID=$ROOT_UUID BOOT_DEV=PARTUUID=$BOOT_UUID ;;
arm64)
	IMG=$O/cua-agentos-pi5.img
	# The Pi 5 needs the Raspberry Pi kernel (RP1: USB, Ethernet; HDMI; Wi-Fi). Their archive key is fetched over HTTPS
	# and must match the pinned fingerprint.
	curl -sSfL --connect-timeout 15 -o "$O/raspberrypi.asc" https://archive.raspberrypi.com/debian/raspberrypi.gpg.key
	[ "$(gpg --show-keys --with-colons "$O/raspberrypi.asc" | awk -F: '/^fpr/ {print $10; exit}')" = $RPI_KEY_FPR ] ||
		{ echo "build-debian-img: Raspberry Pi archive key fingerprint mismatch" >&2; exit 1; }
	# One keyring directory (apt reads it as the namespace's root, which cannot enter this checkout).
	K=$(mktemp -d) && chmod 755 "$K" && trap 'rm -rf "$K"' EXIT
	cp /usr/share/keyrings/debian-archive-keyring.gpg "$K/"
	gpg --dearmor <"$O/raspberrypi.asc" >"$K/raspberrypi.gpg" && chmod 644 "$K"/*
	KEYRINGS=--keyring=$K
	SOURCES="$SOURCES
deb http://archive.raspberrypi.com/debian trixie main"
	PKGS=$PKGS,linux-image-rpi-2712,firmware-brcm80211,wireless-regdb,raspberrypi-archive-keyring
	ROOT_DEV=PARTUUID=41474f53-02 BOOT_DEV=PARTUUID=41474f53-01 ;;
*) echo "build-debian-img: ARCH must be amd64 or arm64" >&2; exit 2 ;;
esac

B=$O/boot-$ARCH
rm -rf "$B" "$O/root-$ARCH.tar" && mkdir -p "$B"
# The namespace's root is a subuid that cannot read this checkout, so files cross with tar-in/sync-out. The overlay goes
# in before the packages, so their kernel and initramfs hooks already run /usr/libexec/agentos/update-boot.
tar -C "$ROOT/rootfs/debian" --owner=0 --group=0 --mode=go-w --sort=name -cf "$O/overlay.tar" .
echo "$SOURCES" | mmdebstrap --mode=unshare --arch="$ARCH" --quiet $KEYRINGS --include="$PKGS" \
	--essential-hook="tar-in '$O/overlay.tar' /" --essential-hook='mkdir -p "$1/boot/firmware"' \
	--customize-hook="copy-in '$DEB' /tmp" --customize-hook="chroot \"\$1\" sh -eu -c '
		dpkg -i /tmp/$(basename "$DEB") && rm /tmp/$(basename "$DEB")
		for v in \$(ls /lib/modules); do /usr/libexec/agentos/update-boot \$v; done
		useradd -m -G agentd-users,video,render,input -s /usr/sbin/nologin agentos
		if [ -n \"\$ROOT_PASSWORD_HASH\" ]; then usermod -p \"\$ROOT_PASSWORD_HASH\" root; else passwd -q -l root; fi
		systemctl -q enable agentd.socket agentd.service agentos-kiosk.service agentos-key-import.service \\
			agentos-bootlog.timer agentos-debug.service NetworkManager.service systemd-timesyncd.service
		systemctl -q disable getty@tty1.service
		echo agentos >/etc/hostname
		printf \"127.0.0.1 localhost\\n127.0.1.1 agentos\\n::1 localhost ip6-localhost ip6-loopback\\n\" >/etc/hosts
		printf \"$ROOT_DEV / ext4 errors=remount-ro 0 1\\n$BOOT_DEV /boot/firmware vfat umask=0077 0 2\\n\" >/etc/fstab
		if [ $ARCH = arm64 ]; then
			echo \"deb [signed-by=/usr/share/keyrings/raspberrypi-archive-keyring.gpg] http://archive.raspberrypi.com/debian trixie main\" \\
				>/etc/apt/sources.list.d/raspi.list
			sed -i /raspberrypi/d /etc/apt/sources.list
		fi'" \
	--customize-hook="sync-out /boot/firmware '$B'" --customize-hook='rm -rf "$1"/boot/firmware/*' \
	trixie "$O/root-$ARCH.tar" -

case $ARCH in
amd64)
	mkdir -p "$B/EFI/BOOT" "$B/loader/entries"
	tar -xOf "$O/root-$ARCH.tar" ./usr/lib/systemd/boot/efi/systemd-bootx64.efi >"$B/EFI/BOOT/BOOTX64.EFI"
	printf 'default agentos.conf\ntimeout 0\n' >"$B/loader/loader.conf"
	printf 'title CUA-AgentOS\nlinux /vmlinuz\ninitrd /initrd.img\noptions root=%s rw console=ttyS0,115200 console=tty1\n' \
		"$ROOT_DEV" >"$B/loader/entries/agentos.conf" ;;
arm64)
	cat >"$B/config.txt" <<'CFG'
# CUA-AgentOS on Raspberry Pi 5 (read by the EEPROM boot loader)
arm_64bit=1
kernel=kernel_2712.img
initramfs initramfs_2712 followkernel
dtoverlay=vc4-kms-v3d
disable_overscan=1
CFG
	echo "console=tty1 root=$ROOT_DEV rootfstype=ext4 rootwait fsck.repair=yes" >"$B/cmdline.txt" ;;
esac
[ -e "$B/vmlinuz" ] || [ -e "$B/kernel_2712.img" ] || { echo "build-debian-img: no kernel on the boot partition" >&2; exit 1; }

# Root: the system plus 1 GiB free for apt and user data.
ROOT_MB=$(($(stat -c %s "$O/root-$ARCH.tar") / 1048576 * 5 / 4 + 1024))
rm -f "$O/root-$ARCH.ext4" "$O/boot-$ARCH.vfat" "$IMG"
# Unpacked where root is this user and other ids are its subuids, so mkfs records the tar's owners (no device nodes:
# /dev is devtmpfs at boot).
unshare --map-root-user --map-auto sh -euc 'R=$1/root-$2; rm -rf "$R" && mkdir "$R"
	tar -C "$R" --exclude="./dev/*" -xf "$R.tar"
	mkfs.ext4 -q -L agentos-root -d "$R" "$R.ext4" "$3M"; rm -rf "$R"' - "$O" "$ARCH" "$ROOT_MB"
mkfs.vfat -C -F 32 -n AGENTOS --invariant "$O/boot-$ARCH.vfat" $((BOOT_MB * 1024)) >/dev/null
MTOOLS_SKIP_CHECK=1 mcopy -s -m -i "$O/boot-$ARCH.vfat" "$B"/* ::/
truncate -s $(((2 + BOOT_MB + ROOT_MB) * 1048576)) "$IMG"
if [ $ARCH = amd64 ]; then
	sfdisk -q "$IMG" <<EOF
label: gpt
label-id: 41474f53-0000-4000-8000-616d64363400
start=2048, size=$((BOOT_MB * 2048)), type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=$BOOT_UUID, name=ESP
start=$(((1 + BOOT_MB) * 2048)), size=$((ROOT_MB * 2048)), type=4F68BCE3-E8CD-4DB1-96E7-FBCAF984B709, uuid=$ROOT_UUID, name=root
EOF
else
	sfdisk -q "$IMG" <<EOF
label: dos
label-id: 0x41474f53
start=2048, size=$((BOOT_MB * 2048)), type=c, bootable
start=$(((1 + BOOT_MB) * 2048)), size=$((ROOT_MB * 2048)), type=83
EOF
fi
dd if="$O/boot-$ARCH.vfat" of="$IMG" bs=1M seek=1 conv=notrunc,sparse status=none
dd if="$O/root-$ARCH.ext4" of="$IMG" bs=1M seek=$((1 + BOOT_MB)) conv=notrunc,sparse status=none
rm -rf "$B" "$O/overlay.tar" "$O/root-$ARCH.tar" "$O/root-$ARCH.ext4" "$O/boot-$ARCH.vfat"
echo "$IMG"

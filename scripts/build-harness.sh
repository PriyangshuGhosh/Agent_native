#!/bin/sh
# Build the disposable Cycle 01 test VM into build/harness/{vmlinuz,initramfs,rootfs.qcow2}.
# No root needed: apk runs in --usermode, fakeroot makes the ext4 image root-owned.
# HARNESS_OUT / HARNESS_INIT / AGENT_INIT (a static agent-init binary) let scripts/build-rootfs-03.sh reuse this;
# AGENTD / TIER1_LIB (scripts/build-rootfs-04.sh) add agentd and its Tier 1 test library; PLAN_FIXTURE
# (scripts/build-rootfs-05.sh) adds the recorded Gemini plan agentd replays; BASE_FS=squashfs / PACKAGES_DIR
# (scripts/build-rootfs-06.sh) ship the root as a read-only SquashFS under a tmpfs-backed OverlayFS, plus the
# capability packages agentd installs; BASE_FS=iso (scripts/build-iso-07.sh) instead finds that SquashFS as
# /rootfs.squashfs on the boot CD (/dev/sr0). Timestamps come from SOURCE_DATE_EPOCH so images are reproducible.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=${HARNESS_OUT:-$ROOT/build/harness}
INIT=${HARNESS_INIT:-/sbin/harness-init}
W=$OUT/work
R=$W/root
EPOCH=${SOURCE_DATE_EPOCH:-1700000000}
ALPINE=${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}/v3.24
APK_TOOLS=apk-tools-static-3.0.8-r0.apk
PKGS="alpine-baselayout busybox busybox-static kmod linux-virt eudev dbus at-spi2-core cage mousepad
	libgcc python3 py3-dbus py3-gobject3 py3-evdev grim font-dejavu adwaita-icon-theme librsvg shared-mime-info"

rm -rf "$W" && mkdir -p "$R" "$W/initramfs"
cd "$W"

curl -sSf --connect-timeout 15 --max-time 120 -o apk-tools.apk "$ALPINE/main/x86_64/$APK_TOOLS"
tar -xzf apk-tools.apk sbin/apk.static 2>/dev/null
apk() { ./sbin/apk.static --usermode --root "$R" --no-scripts --no-cache --timeout 30 \
	-X "$ALPINE/main" -X "$ALPINE/community" "$@"; }

# shortcut: alpine-keys is trusted on HTTPS alone (apk.static ships no keys); pin its sha256 if the harness ever leaves dev.
apk --initdb --allow-untrusted add alpine-keys
apk --keys-dir "$R/etc/apk/keys" add $PKGS

# --no-scripts skipped busybox's own symlink step; recreate it.
for p in $("$R/bin/busybox.static" --list-full); do
	[ -e "$R/$p" ] || [ -L "$R/$p" ] || ln -s /bin/busybox "$R/$p"
done
install -m 0755 "$ROOT/rootfs/harness/harness-init" "$R/sbin/harness-init"
install -D -m 0755 "$ROOT/rootfs/harness/run-primitives.py" "$R/usr/local/bin/run-primitives.py"
if [ -n "${AGENT_INIT:-}" ]; then
	install -D -m 0755 "$AGENT_INIT" "$R/usr/bin/agent-init"
	install -D -m 0755 "$ROOT/rootfs/agent-init/prep" "$R/etc/agent-init/prep"
fi
if [ -n "${AGENTD:-}" ]; then
	install -D -m 0755 "$AGENTD" "$R/usr/bin/agentd"
	install -D -m 0644 "$TIER1_LIB" "$R/usr/lib/agentd/libtier1.so"
	[ -z "${PLAN_FIXTURE:-}" ] || install -D -m 0644 "$PLAN_FIXTURE" "$R/usr/share/agentd/gemini_plan.json"
fi
if [ -n "${PACKAGES_DIR:-}" ]; then
	P=$R/usr/share/agentd/packages
	mkdir -p "$P"
	cp "$PACKAGES_DIR/queue" "$P/queue"
	for d in "$PACKAGES_DIR"/*/; do
		tar -C "$d" --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 -cf "$P/$(basename "$d").tar" .
	done
fi

rm -f "$R/var/log/apk.log"  # install timestamps; the only non-reproducible file in the tree
cp "$R/boot/vmlinuz-virt" "$OUT/vmlinuz"

# Tiny initramfs: static busybox loads the block/fs modules, mounts /dev/vda, switch_roots to harness-init.
M=$R/lib/modules/$(ls "$R/lib/modules")
I=$W/initramfs
mkdir -p "$I/bin" "$I/dev" "$I/proc" "$I/newroot" "$I/lib"
cp "$R/bin/busybox.static" "$I/bin/busybox"
# Resolve deps from modules.dep, deps first; stored uncompressed so busybox insmod can load them.
case ${BASE_FS:-} in
squashfs) MODS="virtio_blk squashfs overlay" DEV=/dev/vda SQUASH=/dev/vda ;;
iso) MODS="sr_mod isofs loop squashfs overlay" DEV=/dev/sr0 SQUASH=/cd/rootfs.squashfs ;;
*) MODS="virtio_blk ext4" DEV=/dev/vda ;;
esac
awk -F': *' -v want="$MODS" '
	{ dep[$1] = $2; n = $1; sub(/.*\//, "", n); sub(/\.ko.*/, "", n); path[n] = $1 }
	function load(f,   a, i, k) { if (f in seen) return; seen[f]; k = split(dep[f], a, " "); for (i = k; i >= 1; i--) load(a[i]); print f }
	END { k = split(want, w, " "); for (i = 1; i <= k; i++) load(path[w[i]]) }' "$M/modules.dep" |
	while read -r ko; do
		b=$(basename "$ko" .gz)
		gzip -dc "$M/$ko" >"$I/lib/$b"
		echo "$b"
	done >"$I/modlist"
cat >"$I/init" <<'INIT'
#!/bin/busybox sh
/bin/busybox mount -t proc proc /proc
/bin/busybox mount -t devtmpfs dev /dev
for m in $(/bin/busybox cat /modlist); do /bin/busybox insmod /lib/$m; done
while [ ! -b DEV ]; do /bin/busybox usleep 10000; done
MOUNT_ROOT
/bin/busybox umount /proc
/bin/busybox mount --move /dev /newroot/dev
exec /bin/busybox switch_root /newroot /sbin/harness-init
INIT
if [ -n "${BASE_FS:-}" ]; then
	[ "$BASE_FS" = squashfs ] || cat >"$W/mount-root" <<'MOUNT'
/bin/busybox mkdir -p /cd
/bin/busybox mount -t iso9660 -o ro /dev/sr0 /cd || { echo "initramfs: mount cdrom failed"; /bin/busybox poweroff -f; }
MOUNT
	# Read-only SquashFS lower + tmpfs upper/work -> OverlayFS root; both layers stay visible under /mnt.
	cat >>"$W/mount-root" <<'MOUNT'
/bin/busybox mkdir -p /lower /rw
/bin/busybox mount -t squashfs -o ro SQUASH /lower || { echo "initramfs: mount squashfs failed"; /bin/busybox poweroff -f; }
/bin/busybox mount -t tmpfs -o mode=0755 rw /rw
/bin/busybox mkdir /rw/upper /rw/work
/bin/busybox mount -t overlay overlay -o lowerdir=/lower,upperdir=/rw/upper,workdir=/rw/work /newroot || { echo "initramfs: mount overlay failed"; /bin/busybox poweroff -f; }
/bin/busybox mount --move /lower /newroot/mnt/base
/bin/busybox mount --move /rw /newroot/mnt/rw
MOUNT
	mkdir -p "$R/mnt/base" "$R/mnt/rw" "$R/data"
	if [ "$BASE_FS" = iso ]; then
		echo '/bin/busybox mount --move /cd /newroot/mnt/cd' >>"$W/mount-root"
		mkdir -p "$R/mnt/cd"
	fi
else
	echo '/bin/busybox mount -t ext4 /dev/vda /newroot || { echo "initramfs: mount /dev/vda failed"; /bin/busybox poweroff -f; }' >"$W/mount-root"
fi
sed -i -e "s|DEV|${DEV:-}|; s|SQUASH|${SQUASH:-}|" "$I/init" "$W/mount-root"
sed -i -e "/^MOUNT_ROOT\$/{r $W/mount-root" -e 'd}' -e "s|/sbin/harness-init|$INIT|" "$I/init"
chmod 0755 "$I/init"
# ISO: the kernel runs agent-init straight from the initramfs (rdinit=/usr/bin/agent-init); it execs /stage1 (this
# script) to mount the real root, which switch_roots back to agent-init there.
if [ "${BASE_FS:-}" = iso ]; then
	install -D -m 0755 "$AGENT_INIT" "$I/usr/bin/agent-init"
	cp "$I/init" "$I/stage1"  # busybox switch_root insists /init is a regular file
fi
(cd "$I" && find . -exec touch -h -d "@$EPOCH" {} + && find . | LC_ALL=C sort |
	cpio -o -H newc -R 0:0 --reproducible --quiet | gzip -9n) >"$OUT/initramfs"

if [ -n "${BASE_FS:-}" ]; then
	env -u SOURCE_DATE_EPOCH mksquashfs "$R" "$OUT/rootfs.squashfs" -comp zstd -all-root -noappend -quiet -no-progress \
		-reproducible -no-xattrs -mkfs-time "$EPOCH" -all-time "$EPOCH"
else
	fakeroot /usr/sbin/mke2fs -q -t ext4 -L harness -d "$R" "$W/rootfs.img" 2G
	qemu-img convert -O qcow2 "$W/rootfs.img" "$OUT/rootfs.qcow2"
fi
rm -rf "$W"
echo "harness: built $OUT"

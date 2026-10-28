#!/bin/sh
# Build the disposable Cycle 01 test VM into build/harness/{vmlinuz,initramfs,rootfs.qcow2}.
# No root needed: apk runs in --usermode, fakeroot makes the ext4 image root-owned.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/build/harness
W=$OUT/work
R=$W/root
ALPINE=${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}/v3.24
APK_TOOLS=apk-tools-static-3.0.8-r0.apk
PKGS="alpine-baselayout busybox busybox-static kmod linux-virt eudev dbus at-spi2-core cage mousepad
	python3 py3-dbus py3-gobject3 py3-evdev grim font-dejavu adwaita-icon-theme librsvg shared-mime-info"

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

cp "$R/boot/vmlinuz-virt" "$OUT/vmlinuz"

# Tiny initramfs: static busybox loads virtio_blk/ext4, mounts /dev/vda, switch_roots to harness-init.
M=$R/lib/modules/$(ls "$R/lib/modules")
I=$W/initramfs
mkdir -p "$I/bin" "$I/dev" "$I/proc" "$I/newroot" "$I/lib"
cp "$R/bin/busybox.static" "$I/bin/busybox"
# Resolve deps from modules.dep, deps first; stored uncompressed so busybox insmod can load them.
awk -F': *' -v want="virtio_blk ext4" '
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
while [ ! -b /dev/vda ]; do /bin/busybox usleep 10000; done
/bin/busybox mount -t ext4 /dev/vda /newroot || { echo "initramfs: mount /dev/vda failed"; /bin/busybox poweroff -f; }
/bin/busybox umount /proc
/bin/busybox mount --move /dev /newroot/dev
exec /bin/busybox switch_root /newroot /sbin/harness-init
INIT
chmod 0755 "$I/init"
(cd "$I" && find . | cpio -o -H newc -R 0:0 --quiet | gzip -9) >"$OUT/initramfs"

fakeroot /usr/sbin/mke2fs -q -t ext4 -L harness -d "$R" "$W/rootfs.img" 2G
qemu-img convert -O qcow2 "$W/rootfs.img" "$OUT/rootfs.qcow2"
rm -rf "$W"
echo "harness: built $OUT"

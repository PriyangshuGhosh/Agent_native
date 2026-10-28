#!/bin/sh
# Build Cycle 02 boot artifacts into build/boot/{vmlinuz,initramfs.cpio.gz}: Alpine virt kernel + static agent-init.
# No root needed. The initramfs holds only /usr/bin/agent-init; agent-init creates its own mountpoints.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/build/boot
W=$OUT/work
ALPINE=${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}/v3.24
APK_TOOLS=apk-tools-static-3.0.8-r0.apk

rm -rf "$W" && mkdir -p "$W/keys-root" "$W/initramfs/usr/bin"

gcc -static -Os -std=c99 -Wall -Wextra -Werror -o "$W/initramfs/usr/bin/agent-init" "$ROOT/agent-init/agent-init.c"
strip "$W/initramfs/usr/bin/agent-init"

if [ ! -f "$OUT/vmlinuz" ]; then
	cd "$W"
	curl -sSf --connect-timeout 15 --max-time 120 -o apk-tools.apk "$ALPINE/main/x86_64/$APK_TOOLS"
	echo "c8e2c88c13ba12a12269b79a3543e1190ff8c0ab0beb32b58cadfd5881c619e3  apk-tools.apk" | sha256sum -c --quiet
	tar -xzf apk-tools.apk sbin/apk.static 2>/dev/null
	apk() { ./sbin/apk.static --usermode --root "$W/keys-root" --no-scripts --no-cache --timeout 30 -X "$ALPINE/main" "$@"; }
	# shortcut: alpine-keys is trusted on HTTPS alone (apk.static ships no keys); pin its sha256 if this leaves dev.
	apk --initdb --allow-untrusted add alpine-keys
	timeout -s KILL 600 ./sbin/apk.static --root "$W/keys-root" --keys-dir "$W/keys-root/etc/apk/keys" --no-cache --timeout 30 \
		-X "$ALPINE/main" fetch -o "$W" linux-virt
	tar -xzf "$W"/linux-virt-*.apk -C "$W" boot/vmlinuz-virt 2>/dev/null
	cp "$W/boot/vmlinuz-virt" "$OUT/vmlinuz"
fi

(cd "$W/initramfs" && find . | sort | cpio -o -H newc -R 0:0 --quiet | gzip -9n) >"$OUT/initramfs.cpio.gz"
rm -rf "$W"
echo "boot: built $OUT"

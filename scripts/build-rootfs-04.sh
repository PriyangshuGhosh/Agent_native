#!/bin/sh
# Build Cycle 04 into build/rootfs-04/{vmlinuz,initramfs,rootfs.qcow2}: the Cycle 03 image plus agentd as
# agent-init's final workload and its Tier 1 test library. No root needed; Rust comes from ~/.cargo (rustup).
# ROOTFS_OUT / PLAN_FIXTURE let scripts/build-rootfs-05.sh reuse this; ARCH=aarch64 CROSS=aarch64-linux-gnu- cross-builds
# every binary (scripts/build-pi5-img.sh).
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
ARCH=${ARCH:-x86_64}
CROSS=${CROSS:-}
B=$ROOT/build
O=$B/obj-$ARCH
SYS=$B/musl-sysroot-$ARCH
ALPINE=${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}/v3.24/main/$ARCH
export PATH=$HOME/.cargo/bin:$PATH
mkdir -p "$O"

# agentd links dynamically against the rootfs's own musl: a fully static musl binary cannot dlopen (Tier 1).
# Link-time sysroot = Alpine's musl, musl-dev and libgcc (std's unwinder is libgcc_s without crt-static).
if [ ! -e "$SYS/usr/lib/libgcc_s.so" ]; then
	rm -rf "$SYS" && mkdir -p "$SYS"
	curl -sSf --connect-timeout 15 --max-time 60 "$ALPINE/APKINDEX.tar.gz" | tar -xzO APKINDEX 2>/dev/null |
		awk '/^P:/ { p = substr($0, 3) } /^V:/ && (p == "musl" || p == "musl-dev" || p == "libgcc") { print p "-" substr($0, 3) ".apk" }' |
		while read -r apk; do
			curl -sSf --connect-timeout 15 --max-time 60 "$ALPINE/$apk" | tar -xz -C "$SYS" 2>/dev/null
		done
	ln -s libgcc_s.so.1 "$SYS/usr/lib/libgcc_s.so"
fi
# RUSTFLAGS reach only --target artifacts, never the host-built proc macros.
CARGO_TARGET_DIR=$B/agentd-target \
RUSTFLAGS="-C linker=${CROSS}gcc -C target-feature=-crt-static -L $SYS/usr/lib \
-C link-arg=--sysroot=$SYS -C link-arg=-Wl,--dynamic-linker=/lib/ld-musl-$ARCH.so.1" \
	cargo build -q --locked --release --target "$ARCH-unknown-linux-musl" --manifest-path "$ROOT/agentd/Cargo.toml"
"${CROSS}gcc" -shared -fPIC -nostdlib -O2 -Wall -Wextra -Werror -o "$O/libtier1.so" "$ROOT/agentd/tier1/tier1.c"

"${CROSS}gcc" -static -Os -std=c99 -Wall -Wextra -Werror -o "$O/agent-init.static" "$ROOT/agent-init/agent-init.c"
"${CROSS}strip" "$O/agent-init.static"
HARNESS_OUT=${ROOTFS_OUT:-$B/rootfs-04} HARNESS_INIT=/usr/bin/agent-init AGENT_INIT=$O/agent-init.static \
AGENTD=$B/agentd-target/$ARCH-unknown-linux-musl/release/agentd TIER1_LIB=$O/libtier1.so ARCH=$ARCH \
	exec "$ROOT/scripts/build-harness.sh"

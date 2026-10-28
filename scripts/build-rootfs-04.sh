#!/bin/sh
# Build Cycle 04 into build/rootfs-04/{vmlinuz,initramfs,rootfs.qcow2}: the Cycle 03 image plus agentd as
# agent-init's final workload and its Tier 1 test library. No root needed; Rust comes from ~/.cargo (rustup).
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=$ROOT/build
SYS=$B/musl-sysroot
ALPINE=${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}/v3.24/main/x86_64
export PATH=$HOME/.cargo/bin:$PATH
mkdir -p "$B"

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
CARGO_TARGET_DIR=$B/agentd-target \
CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="-C target-feature=-crt-static -L $SYS/usr/lib \
-C link-arg=--sysroot=$SYS -C link-arg=-Wl,--dynamic-linker=/lib/ld-musl-x86_64.so.1" \
	cargo build -q --locked --release --target x86_64-unknown-linux-musl --manifest-path "$ROOT/agentd/Cargo.toml"
gcc -shared -fPIC -nostdlib -O2 -Wall -Wextra -Werror -o "$B/libtier1.so" "$ROOT/agentd/tier1/tier1.c"

gcc -static -Os -std=c99 -Wall -Wextra -Werror -o "$B/agent-init-04.static" "$ROOT/agent-init/agent-init.c"
strip "$B/agent-init-04.static"
HARNESS_OUT=$B/rootfs-04 HARNESS_INIT=/usr/bin/agent-init AGENT_INIT=$B/agent-init-04.static \
AGENTD=$B/agentd-target/x86_64-unknown-linux-musl/release/agentd TIER1_LIB=$B/libtier1.so \
	exec "$ROOT/scripts/build-harness.sh"

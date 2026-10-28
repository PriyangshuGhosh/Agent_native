#!/bin/sh
# Build Cycle 03 into build/rootfs-03/{vmlinuz,initramfs,rootfs.qcow2}: the Cycle 01 Alpine rootfs with the
# static agent-init as PID 1 (the initramfs switch_roots straight to it). No root needed.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=$ROOT/build/agent-init.static
mkdir -p "$ROOT/build"
gcc -static -Os -std=c99 -DFINAL_CMD='"/usr/local/bin/run-primitives.py"' -Wall -Wextra -Werror -o "$BIN" "$ROOT/agent-init/agent-init.c"
strip "$BIN"
HARNESS_OUT=$ROOT/build/rootfs-03 HARNESS_INIT=/usr/bin/agent-init AGENT_INIT=$BIN \
	exec "$ROOT/scripts/build-harness.sh"

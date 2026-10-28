#!/bin/sh
# Gate 03 — integration: agent-init (PID 1) brings up D-Bus, the AT-SPI bus and cage itself, then runs the
# Cycle 01 primitives probe under it, and powers the VM off when the probe exits.
# Required serial events (JSON lines on ttyS0, each with "ts_ms"):
#   {"event":"PID1_READY","pid":1,...}                    ts_ms <= 1000, from agent-init
#   {"event":"COMPOSITOR_READY","output":"HEADLESS-1"}    from the probe, once grim sees the output
#   {"event":"INTERACTION_CYCLE_VERIFIED","primitive":"atspi_tree"|"atspi_action"|"uinput"|"screencopy",...}
# QEMU must exit 0 on its own: agent-init's kill(-1)/sync/RB_POWER_OFF path (a panic hangs: panic=0).
# SERIAL_LOG=<file> skips the VM and checks an existing log.
set -eu
[ -n "${GATE_INNER:-}" ] || GATE_INNER=1 exec timeout -s KILL 300 "$0" "$@"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=${ROOTFS_DIR:-$ROOT/build/rootfs-03}

fail=0
if [ -z "${SERIAL_LOG:-}" ]; then
	for f in "$B/vmlinuz" "$B/initramfs" "$B/rootfs.qcow2"; do
		[ -f "$f" ] || { echo "gate-03: missing $f (run scripts/build-rootfs-03.sh)" >&2; exit 2; }
	done
	SERIAL_LOG=$ROOT/build/gate-03-serial.log  # kept for diagnosis
	: >"$SERIAL_LOG"
	rc=0
	# Inner timeout so a hung guest is killed by us, not orphaned by the outer SIGKILL.
	timeout -s KILL 270 qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp 2 \
		-display none -monitor none -nic none -no-reboot -snapshot \
		-kernel "$B/vmlinuz" -initrd "$B/initramfs" \
		-append "root=/dev/vda console=ttyS0 quiet loglevel=0 panic=0" \
		-drive "file=$B/rootfs.qcow2,if=virtio,format=qcow2" \
		-serial "file:$SERIAL_LOG" </dev/null >/dev/null 2>&1 || rc=$?
	[ "$rc" -eq 0 ] || { echo "gate-03: FAIL qemu exit $rc (no clean RB_POWER_OFF)" >&2; fail=1; }
fi

# Keep only well-formed telemetry objects; kernel noise on ttyS0 is ignored.
EVENTS=$(jq -cR 'fromjson? | objects | select((.ts_ms|type)=="number" and (.event|type)=="string")' "$SERIAL_LOG")

check() {
	printf '%s\n' "$EVENTS" | jq -e -s "any(.[]; $2)" >/dev/null || { echo "gate-03: FAIL $1" >&2; fail=1; }
}
v='.event=="INTERACTION_CYCLE_VERIFIED" and .primitive=='
check pid1_ready   '.event=="PID1_READY" and .pid==1 and .ts_ms <= 1000'
check compositor   '.event=="COMPOSITOR_READY" and .output=="HEADLESS-1"'
check atspi_tree   "$v\"atspi_tree\" and .app==\"mousepad\" and (.nodes|numbers) >= 1"
check atspi_action "$v\"atspi_action\" and (.expected|strings|length) > 0 and .actual==.expected"
check uinput       "$v\"uinput\" and (.expected|strings|length) > 0 and .actual==.expected"
check screencopy   "$v\"screencopy\" and (.frames|numbers) >= 10 and (.fps|numbers) >= 10"
exit $fail

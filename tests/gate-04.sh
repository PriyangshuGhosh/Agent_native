#!/bin/sh
# Gate 04 — routing: agent-init (PID 1) brings up D-Bus, AT-SPI and cage, then runs agentd as its final
# workload. agentd proves each capability tier once and exits; agent-init powers the VM off.
# Required serial events (JSON lines on ttyS0, each with "ts_ms"):
#   {"event":"PID1_READY","pid":1,...}                       ts_ms <= 1000
#   {"event":"AGENTD_READY",...}                             ts_ms - PID1_READY.ts_ms <= 3000
#   {"event":"CAPABILITY_VERIFIED","tier":N,"primitive":P,"status":"ok",...}  for (1,ffi_compute),
#                                                            (2,headless_pipe), (3,atspi_ui)
#   {"event":"TIERn_PASS","latency_ms":L,...}                L within the tier budget: 1 / 50 / 20 ms
# QEMU must exit 0 on its own (agent-init's RB_POWER_OFF path; a panic hangs: panic=0).
# SERIAL_LOG=<file> skips the VM and checks an existing log.
set -eu
[ -n "${GATE_INNER:-}" ] || GATE_INNER=1 exec timeout -s KILL 300 "$0" "$@"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=${ROOTFS_DIR:-$ROOT/build/rootfs-04}

fail=0
if [ -z "${SERIAL_LOG:-}" ]; then
	for f in "$B/vmlinuz" "$B/initramfs" "$B/rootfs.qcow2"; do
		[ -f "$f" ] || { echo "gate-04: missing $f (run scripts/build-rootfs-04.sh)" >&2; exit 2; }
	done
	SERIAL_LOG=$ROOT/build/gate-04-serial.log  # kept for diagnosis
	: >"$SERIAL_LOG"
	rc=0
	# Inner timeout so a hung guest is killed by us, not orphaned by the outer SIGKILL.
	timeout -s KILL 270 qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp 2 \
		-display none -monitor none -nic none -no-reboot -snapshot \
		-kernel "$B/vmlinuz" -initrd "$B/initramfs" \
		-append "root=/dev/vda console=ttyS0 quiet loglevel=0 panic=0" \
		-drive "file=$B/rootfs.qcow2,if=virtio,format=qcow2" \
		-serial "file:$SERIAL_LOG" </dev/null >/dev/null 2>&1 || rc=$?
	[ "$rc" -eq 0 ] || { echo "gate-04: FAIL qemu exit $rc (no clean RB_POWER_OFF)" >&2; fail=1; }
fi

# Keep only well-formed telemetry objects; kernel noise on ttyS0 is ignored.
EVENTS=$(jq -cR 'fromjson? | objects | select((.ts_ms|type)=="number" and (.event|type)=="string")' "$SERIAL_LOG")

# check <name> <jq program over the array of events, true = pass>
check() {
	printf '%s\n' "$EVENTS" | jq -e -s "$2" >/dev/null || { echo "gate-04: FAIL $1" >&2; fail=1; }
}
cap() { # cap <tier> <primitive> <budget_ms>
	check "tier$1_$2" "any(.[]; .event==\"CAPABILITY_VERIFIED\" and .tier==$1 and .primitive==\"$2\" and .status==\"ok\")"
	check "tier$1_budget" "any(.[]; .event==\"TIER$1_PASS\" and (.latency_ms|numbers) <= $3)"
}
check pid1_ready   'any(.[]; .event=="PID1_READY" and .pid==1 and .ts_ms <= 1000)'
check agentd_ready '(first(.[] | select(.event=="PID1_READY")).ts_ms) as $p
	| any(.[]; .event=="AGENTD_READY" and .ts_ms - $p <= 3000)'
cap 1 ffi_compute 1
cap 2 headless_pipe 50
cap 3 atspi_ui 20
exit $fail

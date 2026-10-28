#!/bin/sh
# Gate 06 — storage: the root is an OverlayFS over a read-only SquashFS base (tmpfs upper/work), and agentd runs
# an install -> run -> verify lifecycle for test-cap, then an injected bad install (corrupt-cap) that it must
# roll back atomically, leaving the registry and filesystem exactly as before.
# Required serial events (JSON lines on ttyS0, each with "ts_ms"):
#   PID1_READY ts_ms <= 1000; STORAGE_READY {base_ro:true, overlay:true}; AGENTD_READY within 3000 ms of PID1_READY
#   LIFECYCLE_INSTALL + CAPABILITY_INSTALLED {package:"test-cap"}, then LIFECYCLE_VERIFIED {package:"test-cap",
#     status:"ok", in_upper:true, in_base:false} (the staged binary ran from the writable layer)
#   LIFECYCLE_FAIL_INJECTED {package:"corrupt-cap"}, then ROLLBACK_TRIGGERED + CAPABILITY_ROLLBACK, then
#     ROLLBACK_VERIFIED {package:"corrupt-cap", clean:true}; corrupt-cap is never verified ok
#   TASK_COMPLETE {task_id of the lifecycle, status:"success"} after ROLLBACK_VERIFIED
# QEMU must exit 0 on its own (agent-init's RB_POWER_OFF path; a panic hangs: panic=0).
# SERIAL_LOG=<file> skips the VM and checks an existing log.
set -eu
[ -n "${GATE_INNER:-}" ] || GATE_INNER=1 exec timeout -s KILL 300 "$0" "$@"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=${ROOTFS_DIR:-$ROOT/build/rootfs-06}

fail=0
if [ -z "${SERIAL_LOG:-}" ]; then
	for f in "$B/vmlinuz" "$B/initramfs" "$B/rootfs.squashfs"; do
		[ -f "$f" ] || { echo "gate-06: missing $f (run scripts/build-rootfs-06.sh)" >&2; exit 2; }
	done
	SERIAL_LOG=$ROOT/build/gate-06-serial.log  # kept for diagnosis
	: >"$SERIAL_LOG"
	rc=0
	# Inner timeout so a hung guest is killed by us, not orphaned by the outer SIGKILL.
	timeout -s KILL 270 qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp 2 \
		-display none -monitor none -nic none -no-reboot -snapshot \
		-kernel "$B/vmlinuz" -initrd "$B/initramfs" \
		-append "console=ttyS0 quiet loglevel=0 panic=0" \
		-drive "file=$B/rootfs.squashfs,if=virtio,format=raw,readonly=on" \
		-serial "file:$SERIAL_LOG" </dev/null >/dev/null 2>&1 || rc=$?
	[ "$rc" -eq 0 ] || { echo "gate-06: FAIL qemu exit $rc (no clean RB_POWER_OFF)" >&2; fail=1; }
fi

# Keep only well-formed telemetry objects; kernel noise on ttyS0 is ignored.
EVENTS=$(jq -cR 'fromjson? | objects | select((.ts_ms|type)=="number" and (.event|type)=="string")' "$SERIAL_LOG")

# check <name> <jq program over the array of events, true = pass>; $tid = the lifecycle's task_id,
# $i(e; p) = index of the first event e for package p (null if absent).
check() {
	printf '%s\n' "$EVENTS" | jq -e -s "
		def i(e; p): map(.event==e and .package==p) | index(true);
		(first(.[] | select(.event==\"LIFECYCLE_INSTALL\")).task_id // null) as \$tid | $2" \
		>/dev/null || { echo "gate-06: FAIL $1" >&2; fail=1; }
}
check pid1_ready    'any(.[]; .event=="PID1_READY" and .pid==1 and .ts_ms <= 1000)'
check storage_ready 'any(.[]; .event=="STORAGE_READY" and .base_ro==true and .overlay==true)'
check agentd_ready  '(first(.[] | select(.event=="PID1_READY")).ts_ms) as $p
	| any(.[]; .event=="AGENTD_READY" and .ts_ms - $p <= 3000)'
check task_start    '$tid | type == "string" and length > 0'
check install       'i("LIFECYCLE_INSTALL"; "test-cap") != null and i("CAPABILITY_INSTALLED"; "test-cap") != null'
check verified      'i("LIFECYCLE_INSTALL"; "test-cap") as $a | any(.[$a+1:][]; .event=="LIFECYCLE_VERIFIED"
	and .package=="test-cap" and .status=="ok" and .in_upper==true and .in_base==false)'
check rollback      'i("LIFECYCLE_FAIL_INJECTED"; "corrupt-cap") as $f | i("ROLLBACK_TRIGGERED"; "corrupt-cap") as $r
	| i("ROLLBACK_VERIFIED"; "corrupt-cap") as $v
	| $f != null and $r != null and $v != null and $f < $r and $r < $v and .[$v].clean == true
	and i("CAPABILITY_ROLLBACK"; "corrupt-cap") != null'
check corrupt_never_ok 'all(.[]; (.event=="LIFECYCLE_VERIFIED" and .package=="corrupt-cap" and .status=="ok") | not)'
check task_complete 'i("ROLLBACK_VERIFIED"; "corrupt-cap") as $v
	| (map(.event=="TASK_COMPLETE" and .task_id==$tid and .status=="success") | index(true)) as $c
	| $v != null and $c != null and $c > $v'
exit $fail

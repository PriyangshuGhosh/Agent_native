#!/bin/sh
# Gate 05 — cognition: agentd loads a recorded gemini-2.5-flash plan (tests/fixtures/gemini_plan.json), validates
# each directive's precondition, dispatches it to its tier, verifies the postcondition, and replans once on a
# deliberately wrong prediction in the recording (step 1 expects role "entry"; mousepad's widget is "text").
# Required serial events (JSON lines on ttyS0, each with "ts_ms"):
#   PID1_READY ts_ms <= 1000; AGENTD_READY within 3000 ms of it
#   TASK_START {task_id}
#   STEP_VERIFIED {task_id, step:N, status:"ok"} for steps 1,2,3 on tiers 3,2,1 (UI input -> pipe -> FFI)
#   REPLAN_TRIGGERED {step:N, attempt<=3} followed later by STEP_VERIFIED ok for that same step
#   TASK_COMPLETE {task_id, status:"success"} and WORKFLOW_COMPLETE, after the last step
# QEMU must exit 0 on its own (agent-init's RB_POWER_OFF path; a panic hangs: panic=0).
# SERIAL_LOG=<file> skips the VM and checks an existing log.
set -eu
[ -n "${GATE_INNER:-}" ] || GATE_INNER=1 exec timeout -s KILL 300 "$0" "$@"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=${ROOTFS_DIR:-$ROOT/build/rootfs-05}

fail=0
if [ -z "${SERIAL_LOG:-}" ]; then
	for f in "$B/vmlinuz" "$B/initramfs" "$B/rootfs.qcow2"; do
		[ -f "$f" ] || { echo "gate-05: missing $f (run scripts/build-rootfs-05.sh)" >&2; exit 2; }
	done
	SERIAL_LOG=$ROOT/build/gate-05-serial.log  # kept for diagnosis
	: >"$SERIAL_LOG"
	rc=0
	# Inner timeout so a hung guest is killed by us, not orphaned by the outer SIGKILL.
	timeout -s KILL 270 qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp 2 \
		-display none -monitor none -nic none -no-reboot -snapshot \
		-kernel "$B/vmlinuz" -initrd "$B/initramfs" \
		-append "root=/dev/vda console=ttyS0 quiet loglevel=0 panic=0" \
		-drive "file=$B/rootfs.qcow2,if=virtio,format=qcow2" \
		-serial "file:$SERIAL_LOG" </dev/null >/dev/null 2>&1 || rc=$?
	[ "$rc" -eq 0 ] || { echo "gate-05: FAIL qemu exit $rc (no clean RB_POWER_OFF)" >&2; fail=1; }
fi

# Keep only well-formed telemetry objects; kernel noise on ttyS0 is ignored.
EVENTS=$(jq -cR 'fromjson? | objects | select((.ts_ms|type)=="number" and (.event|type)=="string")' "$SERIAL_LOG")

# check <name> <jq program over the array of events, true = pass>; $tid = TASK_START's task_id.
check() {
	printf '%s\n' "$EVENTS" | jq -e -s "(first(.[] | select(.event==\"TASK_START\")).task_id // null) as \$tid | $2" \
		>/dev/null || { echo "gate-05: FAIL $1" >&2; fail=1; }
}
check pid1_ready   'any(.[]; .event=="PID1_READY" and .pid==1 and .ts_ms <= 1000)'
check agentd_ready '(first(.[] | select(.event=="PID1_READY")).ts_ms) as $p
	| any(.[]; .event=="AGENTD_READY" and .ts_ms - $p <= 3000)'
check task_start   '$tid | type == "string" and length > 0'
check steps_tiers  '[.[] | select(.event=="STEP_VERIFIED" and .status=="ok" and .task_id==$tid) | [.step, .tier]]
	== [[1,3],[2,2],[3,1]]'
check replan       '(map(.event=="REPLAN_TRIGGERED" and .task_id==$tid) | index(true)) as $r | $r != null
	and .[$r].attempt <= 3
	and (.[$r].step as $s | any(.[$r+1:][]; .event=="STEP_VERIFIED" and .step==$s and .status=="ok"))'
check task_complete '(map(.event=="STEP_VERIFIED") | rindex(true)) as $l
	| (map(.event=="TASK_COMPLETE" and .task_id==$tid and .status=="success") | index(true)) as $c
	| $l != null and $c != null and $c > $l'
check workflow_complete 'any(.[]; .event=="WORKFLOW_COMPLETE" and .task_id==$tid)'
exit $fail

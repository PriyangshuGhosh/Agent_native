#!/bin/sh
# Gate 08 — evaluation rubric. Boots the Cycle 07 ISO from the CD-ROM only (no -kernel/-initrd) and scores five weighted
# categories from serial telemetry and exit codes; every one must pass (100/100).
#   kernel_handoff (20): PID1_READY.cmdline has rdinit=/usr/bin/agent-init (the kernel exec'd agent-init itself)
#   bare_metal_pid1 (20): PID1_READY pid 1, comm agent-init, ts_ms <= 1000, VFS mounts, reap test, 0 zombies, no other process
#   perception_3tier (25): TIER{1,2,3}_PASS within the fixed 1 / 50 / 20 ms budgets (not agentd's own budget_ms),
#                          screencopy >= 10 FPS, AGENTD_READY <= 3000 ms after PID1_READY
#   app_lifecycle (25): STORAGE_READY; test-cap installed to the overlay upper and verified; corrupt-cap fault injected,
#                       CAPABILITY_ROLLBACK + clean ROLLBACK_VERIFIED; registry ends as ["test-cap"]
#   immutable_artifact (10): run1.iso == run2.iso == booted ISO (sha256); ISOLINUX on the ISO loaded the kernel
#                            (cmdline BOOT_IMAGE=/boot/vmlinuz); QEMU exits 0
# Each category prints one {"event":"RUBRIC_PASS"|"RUBRIC_FAIL","item":...,"weight":...} line on stdout (also kept in
# build/gate-08-rubric.jsonl). ISO=<file> boots another copy (e.g. release/cua-agentos.iso); SERIAL_LOG=<file> skips the VM.
set -eu
[ -n "${GATE_INNER:-}" ] || GATE_INNER=1 exec timeout -s KILL 300 "$0" "$@"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=$ROOT/build/iso
ISO=${ISO:-$D/cua-agentos.iso}
RUBRIC=${RUBRIC:-$ROOT/build/gate-08-rubric.jsonl}

for f in "$ISO" "$D/run1.iso" "$D/run2.iso"; do
	[ -f "$f" ] || { echo "gate-08: missing $f (run scripts/build-iso-07.sh)" >&2; exit 2; }
done
h1=$(sha256sum <"$D/run1.iso") h2=$(sha256sum <"$D/run2.iso") h=$(sha256sum <"$ISO")
repro=false
[ "$h1" = "$h2" ] && [ "$h" = "$h1" ] && repro=true

rc=0
if [ -z "${SERIAL_LOG:-}" ]; then
	SERIAL_LOG=$ROOT/build/gate-08-serial.log  # kept for diagnosis and the grading report
	: >"$SERIAL_LOG"
	# Inner timeout so a hung guest is killed by us, not orphaned by the outer SIGKILL.
	timeout -s KILL 270 qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp 2 -snapshot -nic none \
		-nographic -monitor none -no-reboot -boot d -cdrom "$ISO" \
		-serial "file:$SERIAL_LOG" </dev/null >/dev/null 2>&1 || rc=$?
fi

# Keep only well-formed telemetry objects; bootloader and kernel noise on ttyS0 is ignored.
EVENTS=$(jq -cR 'fromjson? | objects | select((.ts_ms|type)=="number" and (.event|type)=="string")' "$SERIAL_LOG")

: >"$RUBRIC"
score=0
rubric() {  # <item> <weight> <jq predicate over the event array>
	if printf '%s\n' "$EVENTS" | jq -e -s --argjson repro "$repro" --argjson rc "$rc" "$3" >/dev/null; then
		ev=RUBRIC_PASS score=$((score + $2))
	else
		ev=RUBRIC_FAIL
	fi
	jq -cn --arg e "$ev" --arg i "$1" --argjson w "$2" '{event:$e, item:$i, weight:$w}' | tee -a "$RUBRIC"
}

rubric kernel_handoff 20 'any(.[]; .event=="PID1_READY" and ((.cmdline // "") | split(" ") | index("rdinit=/usr/bin/agent-init")) != null)'
rubric bare_metal_pid1 20 'any(.[]; .event=="PID1_READY" and .pid==1 and .comm=="agent-init" and .ts_ms <= 1000
	and .mounts == {"/proc":"proc","/sys":"sysfs","/dev":"devtmpfs","/dev/pts":"devpts","/run":"tmpfs","/tmp":"tmpfs"}
	and .reap_test.reaped==true and .zombies==0 and .user_procs==1)'
rubric perception_3tier 25 '. as $all | (first(.[] | select(.event=="PID1_READY")).ts_ms) as $p
	| all([1, 1], [2, 50], [3, 20]; . as [$t, $b] | any($all[]; .event == "TIER\($t)_PASS" and (.latency_ms|numbers) <= $b))
	and any(.[]; .event=="INTERACTION_CYCLE_VERIFIED" and .primitive=="screencopy" and .fps >= 10)
	and any(.[]; .event=="AGENTD_READY" and .ts_ms - $p <= 3000)'
rubric app_lifecycle 25 'any(.[]; .event=="STORAGE_READY" and .base_ro==true and .overlay==true)
	and any(.[]; .event=="LIFECYCLE_INSTALL" and .package=="test-cap")
	and any(.[]; .event=="LIFECYCLE_VERIFIED" and .package=="test-cap" and .status=="ok" and .in_upper==true and .in_base==false)
	and any(.[]; .event=="LIFECYCLE_FAIL_INJECTED" and .package=="corrupt-cap")
	and any(.[]; .event=="CAPABILITY_ROLLBACK" and .package=="corrupt-cap")
	and any(.[]; .event=="ROLLBACK_VERIFIED" and .package=="corrupt-cap" and .clean==true)
	and any(.[]; .event=="TASK_COMPLETE" and .task_id=="t06-lifecycle" and .status=="success" and .registry==["test-cap"])'
rubric immutable_artifact 10 '$repro and $rc == 0
	and any(.[]; .event=="PID1_READY" and ((.cmdline // "") | split(" ") | index("BOOT_IMAGE=/boot/vmlinuz")) != null)'

echo "gate-08: score $score/100" >&2
[ "$score" -eq 100 ]

#!/bin/sh
# Gate 07 — packaging: the Cycle 06 system as a bootable ISO. QEMU boots it from the CD-ROM only (no -kernel/-initrd:
# ISOLINUX on the ISO loads the kernel and initramfs, which loop-mounts /rootfs.squashfs from the CD as the base).
# Required serial events (JSON lines on ttyS0, each with "ts_ms"):
#   PID1_READY ts_ms <= 1000; STORAGE_READY {base_ro:true, overlay:true}; AGENTD_READY within 3000 ms of PID1_READY;
#   TASK_COMPLETE {status:"success"} (the agent reaches and finishes its unattended task)
# QEMU must exit 0 on its own (agent-init's RB_POWER_OFF path; a panic hangs: panic=0).
# Reproducibility: scripts/build-iso-07.sh builds the ISO twice from scratch into build/iso/run{1,2}.iso; their
# sha256 must match, and the booted build/iso/cua-agentos.iso must be that same image.
# SERIAL_LOG=<file> skips the VM and checks an existing log.
set -eu
[ -n "${GATE_INNER:-}" ] || GATE_INNER=1 exec timeout -s KILL 300 "$0" "$@"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=$ROOT/build/iso
ISO=$D/cua-agentos.iso

fail=0
for f in "$ISO" "$D/run1.iso" "$D/run2.iso"; do
	[ -f "$f" ] || { echo "gate-07: missing $f (run scripts/build-iso-07.sh)" >&2; exit 2; }
done
h1=$(sha256sum <"$D/run1.iso") h2=$(sha256sum <"$D/run2.iso") h=$(sha256sum <"$ISO")
[ "$h1" = "$h2" ] || { echo "gate-07: FAIL run1.iso and run2.iso differ" >&2; fail=1; }
[ "$h" = "$h1" ] || { echo "gate-07: FAIL cua-agentos.iso is not the reproduced image" >&2; fail=1; }

if [ -z "${SERIAL_LOG:-}" ]; then
	SERIAL_LOG=$ROOT/build/gate-07-serial.log  # kept for diagnosis
	: >"$SERIAL_LOG"
	rc=0
	# Inner timeout so a hung guest is killed by us, not orphaned by the outer SIGKILL.
	timeout -s KILL 270 qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp 2 -snapshot -nic none \
		-nographic -monitor none -no-reboot -boot d -cdrom "$ISO" \
		-serial "file:$SERIAL_LOG" </dev/null >/dev/null 2>&1 || rc=$?
	[ "$rc" -eq 0 ] || { echo "gate-07: FAIL qemu exit $rc (no clean RB_POWER_OFF)" >&2; fail=1; }
fi

# Keep only well-formed telemetry objects; bootloader and kernel noise on ttyS0 is ignored.
EVENTS=$(jq -cR 'fromjson? | objects | select((.ts_ms|type)=="number" and (.event|type)=="string")' "$SERIAL_LOG")

check() {
	printf '%s\n' "$EVENTS" | jq -e -s "$2" >/dev/null || { echo "gate-07: FAIL $1" >&2; fail=1; }
}
check pid1_ready    'any(.[]; .event=="PID1_READY" and .pid==1 and .ts_ms <= 1000)'
check storage_ready 'any(.[]; .event=="STORAGE_READY" and .base_ro==true and .overlay==true)'
check agentd_ready  '(first(.[] | select(.event=="PID1_READY")).ts_ms) as $p
	| any(.[]; .event=="AGENTD_READY" and .ts_ms - $p <= 3000)'
check task_complete 'any(.[]; .event=="TASK_COMPLETE" and .status=="success")'
exit $fail

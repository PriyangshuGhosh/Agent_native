#!/bin/sh
# Gate 02 — boot core: agent-init as PID 1 from an initramfs under KVM.
# All evidence is fields on the PID1_READY serial event (emitted by agent-init itself):
#   {"ts_ms":N,"event":"PID1_READY","pid":1,"comm":"agent-init",
#    "mounts":{"/proc":"proc","/sys":"sysfs","/dev":"devtmpfs","/dev/pts":"devpts","/run":"tmpfs","/tmp":"tmpfs"},
#    "reap_test":{"pid":P,"reaped":true},"zombies":0,"user_procs":1}
# mounts come from /proc/self/mounts; zombies/user_procs from a /proc scan (user_procs==1: nothing but PID 1,
# so no systemd or display manager). agent.test_poweroff on the cmdline makes agent-init reboot(RB_POWER_OFF)
# after PID1_READY; QEMU exiting 0 on its own is the proof of a clean shutdown (a panic hangs: panic=0).
# SERIAL_LOG=<file> skips the VM and checks an existing log.
set -eu
[ -n "${GATE_INNER:-}" ] || GATE_INNER=1 exec timeout -s KILL 300 "$0" "$@"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=${BOOT_DIR:-$ROOT/build/boot}

fail=0
if [ -z "${SERIAL_LOG:-}" ]; then
	for f in "$B/vmlinuz" "$B/initramfs.cpio.gz"; do
		[ -f "$f" ] || { echo "gate-02: missing $f (run scripts/build-initramfs-02.sh)" >&2; exit 2; }
	done
	SERIAL_LOG=$ROOT/build/gate-02-serial.log  # kept for diagnosis
	: >"$SERIAL_LOG"
	rc=0
	timeout -s KILL 60 qemu-system-x86_64 -enable-kvm -cpu host -m 512 -smp 1 \
		-nographic -monitor none -nic none -no-reboot \
		-kernel "$B/vmlinuz" -initrd "$B/initramfs.cpio.gz" \
		-append "console=ttyS0 quiet loglevel=0 panic=0 rdinit=/usr/bin/agent-init agent.test_poweroff" \
		-serial "file:$SERIAL_LOG" </dev/null >/dev/null 2>&1 || rc=$?
	[ "$rc" -eq 0 ] || { echo "gate-02: FAIL qemu exit $rc (no clean RB_POWER_OFF)" >&2; fail=1; }
fi

EVENTS=$(jq -cR 'fromjson? | objects | select((.ts_ms|type)=="number" and (.event|type)=="string")' "$SERIAL_LOG")

check() {
	printf '%s\n' "$EVENTS" | jq -e -s "any(.[]; .event==\"PID1_READY\" and ($2))" >/dev/null ||
		{ echo "gate-02: FAIL $1" >&2; fail=1; }
}
check budget     '.ts_ms <= 1000'
check pid1       '.pid == 1 and .comm == "agent-init"'
check mounts     '.mounts == {"/proc":"proc","/sys":"sysfs","/dev":"devtmpfs","/dev/pts":"devpts","/run":"tmpfs","/tmp":"tmpfs"}'
check reaping    '.reap_test.reaped == true and (.reap_test.pid|numbers) > 1 and .zombies == 0'
check no_systemd '.user_procs == 1'
exit $fail

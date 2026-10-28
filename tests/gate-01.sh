#!/bin/sh
# Gate 01 — primitives: headless Wayland, AT-SPI→JSON + actions, uinput, screencopy ≥10 FPS.
# Boots the disposable KVM harness guest (-snapshot, no NIC) so uinput never touches the host.
#
# Guest contract: the probe in build/harness/ runs cage on HEADLESS-1 with mousepad, prints one JSON
# object per line on ttyS0, then powers off. Required events:
#   {"event":"COMPOSITOR_READY","output":"HEADLESS-1"}
#   {"event":"INTERACTION_CYCLE_VERIFIED","primitive":"atspi_tree","app":"mousepad","nodes":N}
#   {"event":"INTERACTION_CYCLE_VERIFIED","primitive":"atspi_action","expected":S,"actual":S}  # SetTextContents, read back
#   {"event":"INTERACTION_CYCLE_VERIFIED","primitive":"uinput","expected":S,"actual":S}        # typed keys, read back via AT-SPI
#   {"event":"INTERACTION_CYCLE_VERIFIED","primitive":"screencopy","frames":N,"fps":F}
# Every object also carries "ts_ms". SERIAL_LOG=<file> skips the VM and checks an existing log.
set -eu
[ -n "${GATE_INNER:-}" ] || GATE_INNER=1 exec timeout -s KILL 300 "$0" "$@"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
H=${HARNESS_DIR:-$ROOT/build/harness}

if [ -z "${SERIAL_LOG:-}" ]; then
	for f in "$H/vmlinuz" "$H/initramfs" "$H/rootfs.qcow2"; do
		[ -f "$f" ] || { echo "gate-01: missing $f (build the harness first)" >&2; exit 2; }
	done
	SERIAL_LOG=$ROOT/build/gate-01-serial.log  # kept for diagnosis
	: >"$SERIAL_LOG"
	# Inner timeout so a hung guest is killed by us, not orphaned by the outer SIGKILL.
	timeout -s KILL 270 qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -smp 2 \
		-display none -monitor none -nic none -no-reboot -snapshot \
		-kernel "$H/vmlinuz" -initrd "$H/initramfs" \
		-append "root=/dev/vda console=ttyS0 quiet loglevel=0 panic=-1" \
		-drive "file=$H/rootfs.qcow2,if=virtio,format=qcow2" \
		-serial "file:$SERIAL_LOG"
fi

# Keep only well-formed telemetry objects; kernel noise on ttyS0 is ignored.
EVENTS=$(jq -cR 'fromjson? | objects | select((.ts_ms|type)=="number" and (.event|type)=="string")' "$SERIAL_LOG")

fail=0
check() {
	printf '%s\n' "$EVENTS" | jq -e -s "any(.[]; $2)" >/dev/null || { echo "gate-01: FAIL $1" >&2; fail=1; }
}
v='.event=="INTERACTION_CYCLE_VERIFIED" and .primitive=='
check compositor  '.event=="COMPOSITOR_READY" and .output=="HEADLESS-1"'
check atspi_tree  "$v\"atspi_tree\" and .app==\"mousepad\" and (.nodes|numbers) >= 1"
check atspi_action "$v\"atspi_action\" and (.expected|strings|length) > 0 and .actual==.expected"
check uinput      "$v\"uinput\" and (.expected|strings|length) > 0 and .actual==.expected"
check screencopy  "$v\"screencopy\" and (.frames|numbers) >= 10 and (.fps|numbers) >= 10"
exit $fail

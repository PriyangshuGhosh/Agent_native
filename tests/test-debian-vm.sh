#!/bin/sh
# Debian base, step 1: boots the stock Debian 13 cloud image in a throwaway KVM guest (-snapshot: the image is never
# written; user-mode NAT, no host disk), installs build/deb/agentd_*.deb and checks the service from inside the guest.
# Prints one "CHECK <name> ok|fail" line per check; exits 0 iff all expected checks are ok.
# The live check needs a key file (GEMINI_KEY_FILE, default ./GEMINI_API_KEY.env, bare key); it is copied only into the
# guest's seed ISO, which is deleted on exit. Needs: scripts/fetch-debian-cloud.sh, scripts/build-deb.sh.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMG=$ROOT/build/debian-cloud/debian-13-genericcloud-amd64.qcow2
DEB=$(ls "$ROOT"/build/deb/agentd_*_amd64.deb)
KEY_FILE=${GEMINI_KEY_FILE:-$ROOT/GEMINI_API_KEY.env}
O=$ROOT/build/debian-vm
mkdir -p "$O"
S=$(mktemp -d "$O/seed.XXXXXX")
trap 'rm -rf "$S"' EXIT INT TERM
umask 077

cp "$DEB" "$S/agentd.deb"
EXPECT="installed_active ready_without_key no_key_fails_cleanly unprivileged socket_root_only crash_restarted"
if [ -r "$KEY_FILE" ]; then
	printf 'GEMINI_API_KEY=%s\n' "$(tr -d ' \r\n' <"$KEY_FILE")" >"$S/gemini.env"
	[ -z "${AGENTD_MODEL:-}" ] || echo "AGENTD_MODEL=$AGENTD_MODEL" >>"$S/gemini.env"
	EXPECT="$EXPECT live_task_verified key_not_logged"
fi
printf 'instance-id: agentd-test\nlocal-hostname: agentd-test\n' >"$S/meta-data"
cat >"$S/user-data" <<'UD'
#cloud-config
runcmd:
  - [sh, -c, "mkdir -p /mnt/seed && mount -o ro /dev/disk/by-label/cidata /mnt/seed && sh /mnt/seed/guest.sh; poweroff"]
UD
cat >"$S/guest.sh" <<'GUEST'
# Runs as root in the guest; results go to the second serial port (ttyS0 is the console, reset by its getty).
exec >/dev/ttyS1 2>&1
check() { if [ "$2" = 0 ]; then echo "CHECK $1 ok"; else echo "CHECK $1 fail"; fi; }
active() { for _ in 1 2 3 4 5 6 7 8 9 10; do systemctl is-active -q agentd && return 0; sleep 1; done; return 1; }
journal() { journalctl -u agentd -o cat --no-pager; }

apt-get update -q >/dev/null 2>&1; apt-get install -y -q /mnt/seed/agentd.deb >/dev/null 2>&1
active; check installed_active $?
journal | grep AGENTD_READY | grep -q '"planner":"unavailable"'; check ready_without_key $?

out=$(agentd ask "upper-case the word hello"); rc=$?
echo "$out"
[ $rc = 1 ] && echo "$out" | grep TASK_COMPLETE | grep -q 'planner unavailable' && active; check no_key_fails_cleanly $?

pid=$(systemctl show -p MainPID --value agentd)
[ "$(ps -o user= -p "$pid")" != root ]; check unprivileged $?
! setpriv --reuid=nobody --regid=nogroup --clear-groups agentd ask hello >/dev/null 2>&1; check socket_root_only $?

kill -9 "$pid"; sleep 4
active && [ "$(systemctl show -p MainPID --value agentd)" != "$pid" ] && [ "$(systemctl show -p NRestarts --value agentd)" = 1 ]
check crash_restarted $?

if [ -e /mnt/seed/gemini.env ]; then
	install -m 600 /mnt/seed/gemini.env /etc/agentd/gemini.env
	systemctl restart agentd; active
	out=$(agentd ask "Upper-case the text: hello agentos"); rc=$?
	echo "$out"
	[ $rc = 0 ] && echo "$out" | grep -q WORKFLOW_COMPLETE && echo "$out" | grep -q '"source":"live"'; check live_task_verified $?
	key=$(sed -n 's/^GEMINI_API_KEY=//p' /etc/agentd/gemini.env)
	! journal | grep -qF "$key" && ! journalctl -b -o cat --no-pager | grep -qF "$key"; check key_not_logged $?
fi
echo "GUEST_DONE"
GUEST
xorriso -as mkisofs -quiet -V cidata -J -r -o "$S/seed.iso" "$S/user-data" "$S/meta-data" "$S/guest.sh" "$S/agentd.deb" \
	$( [ -e "$S/gemini.env" ] && echo "$S/gemini.env" ) 2>/dev/null

timeout -s KILL 300 qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -smp 2 -snapshot -nographic -no-reboot \
	-drive file="$IMG",if=virtio,format=qcow2 -drive file="$S/seed.iso",media=cdrom,readonly=on \
	-nic user,model=virtio-net-pci -serial file:"$O/console.log" -serial file:"$O/serial.log" -monitor none -display none >/dev/null 2>&1 || true

tr -d '\r' <"$O/serial.log" | grep -E '^CHECK |^\{"ts_ms"' || true
fail=0
for c in $EXPECT; do
	tr -d '\r' <"$O/serial.log" | grep -qx "CHECK $c ok" || { echo "missing or failed: $c" >&2; fail=1; }
done
exit $fail

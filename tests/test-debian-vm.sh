#!/bin/sh
# Debian base, steps 1-2: boots the stock Debian 13 cloud image in a throwaway KVM guest (-snapshot: the image is never
# written; user-mode NAT, no host disk), installs build/deb/agentd_*.deb and checks the service and
# the tty1 console from inside the guest.
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
EXPECT="installed_active ready_without_key no_key_fails_cleanly unprivileged socket_group_only console_on_tty1
	console_offline crash_restarted broker_sandboxed broker_identities broker_status broker_rejects broker_restart_verified
	broker_approval_allowed broker_approval_refused broker_approval_timeout broker_hangup_cancels broker_rate_limit broker_audit"
if [ -r "$KEY_FILE" ]; then
	printf 'GEMINI_API_KEY=%s\n' "$(tr -d ' \r\n' <"$KEY_FILE")" >"$S/gemini.env"
	[ -z "${AGENTD_MODEL:-}" ] || echo "AGENTD_MODEL=$AGENTD_MODEL" >>"$S/gemini.env"
	EXPECT="$EXPECT live_task_verified console_live live_broker_restart console_approval key_not_logged"
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
failed=0
check() { if [ "$2" = 0 ]; then echo "CHECK $1 ok"; else echo "CHECK $1 fail"; failed=1; fi; }
active() { for _ in 1 2 3 4 5 6 7 8 9 10; do systemctl is-active -q agentd && return 0; sleep 1; done; return 1; }
journal() { journalctl -u agentd -o cat --no-pager; }
# The console as an unprivileged user in group agentd-users, with the given lines as typed input.
console() { printf '%s\n' "$@" | setpriv --reuid=nobody --regid=nogroup --groups="$(getent group agentd-users | cut -d: -f3)" agentd console; }

apt-get update -q >/dev/null 2>&1; apt-get install -y -q /mnt/seed/agentd.deb >/dev/null 2>&1
active; check installed_active $?
journal | grep AGENTD_READY | grep -q '"planner":"unavailable"'; check ready_without_key $?

out=$(agentd ask "upper-case the word hello"); rc=$?
echo "$out"
[ $rc = 1 ] && echo "$out" | grep TASK_COMPLETE | grep -q 'planner unavailable' && active; check no_key_fails_cleanly $?

pid=$(systemctl show -p MainPID --value agentd)
[ "$pid" -gt 0 ] && [ "$(ps -o user= -p "$pid")" != root ]; check unprivileged $?
! setpriv --reuid=nobody --regid=nogroup --clear-groups agentd ask hello >/dev/null 2>&1; check socket_group_only $?

cpid=$(systemctl show -p MainPID --value agentd-console)
systemctl is-active -q agentd-console && ! systemctl is-active -q getty@tty1 && [ "$(ps -o user= -p "$cpid")" != root ] &&
	[ "$(readlink /proc/"$cpid"/fd/0)" = /dev/tty1 ]; check console_on_tty1 $?
out=$(console help status "Upper-case the text: hello"); rc=$?
echo "$out"
[ $rc = 0 ] && echo "$out" | grep -q "Planner: unavailable" && echo "$out" | grep -q "I can't plan this right now" &&
	echo "$out" | grep -q "Nothing was changed"; check console_offline $?

[ "$pid" -gt 0 ] && kill -9 "$pid"; sleep 4  # never kill 0: that is this script's own process group
active && [ "$(systemctl show -p MainPID --value agentd)" != "$pid" ] && [ "$(systemctl show -p NRestarts --value agentd)" = 1 ]
check crash_restarted $?

# Broker: requests are sent with the running agentd's real uid and groups. The policy names units a cloud image may
# lack, so harmless stand-ins are created for those (this guest is thrown away).
for u in cron NetworkManager systemd-timesyncd; do
	[ "$(systemctl show -p LoadState --value $u.service)" = loaded ] || printf '[Service]\nExecStart=/bin/sleep infinity\n' >/etc/systemd/system/$u.service
done
systemctl daemon-reload; systemctl unmask -q systemd-timesyncd.service 2>/dev/null; systemctl start cron.service NetworkManager.service systemd-timesyncd.service
B=/run/agentd-broker.sock AP=/run/agentd-approve.sock BC="python3 /mnt/seed/brokerclient.py"
apid=$(systemctl show -p MainPID --value agentd)
AU=$(awk '/^Uid:/{print $2}' /proc/"$apid"/status) AG=$(awk '/^Gid:/{print $2}' /proc/"$apid"/status)
AGS=$(awk '/^Groups:/{$1=""; print}' /proc/"$apid"/status | xargs | tr ' ' ,)
as_agentd() { setpriv --reuid="$AU" --regid="$AG" --groups="$AGS" $BC "$@"; }
as_console() { setpriv --reuid=nobody --regid=nogroup --groups="$(getent group agentd-users | cut -d: -f3)" $BC "$@"; }
req() { printf '{"op":"service.%s","unit":"%s.service","task_id":"t","step":1}' "$1" "$2"; }
since() { systemctl show -p ActiveEnterTimestampMonotonic --value "$1.service"; }
AUD=/var/log/agentd-broker/audit.jsonl
# Starts an NM restart in the background and waits until the broker is asking; sets ID.
ask_nm() { setpriv --reuid="$AU" --regid="$AG" --groups="$AGS" $BC $B "$(req restart NetworkManager)" >/run/nm.out 2>&1 & NMP=$!; ID=; for _ in $(seq 50); do ID=$(sed -n 's/.*"id":\([0-9]*\).*/\1/p' /run/nm.out); [ -n "$ID" ] && return; sleep 0.1; done; }

as_agentd $B "$(req status cron)" | grep -q '"status":"ok"'; check broker_status $?
bpid=$(systemctl show -p MainPID --value agentd-broker)
[ "$(awk '/^CapEff:/{print $2}' /proc/"$bpid"/status)" = 0000000000000000 ] && [ "$(awk '/^NoNewPrivs:/{print $2}' /proc/"$bpid"/status)" = 1 ]; check broker_sandboxed $?
! as_agentd $AP '{"id":1}' 2>/dev/null && ! as_console $B "$(req status cron)" 2>/dev/null &&
	! setpriv --reuid=nobody --regid=nogroup --clear-groups $BC $B "$(req status cron)" 2>/dev/null &&
	! setpriv --reuid=nobody --regid=nogroup --clear-groups $BC $AP '{"id":1}' 2>/dev/null; check broker_identities $?
r=0; before=$(since cron)
long=$(head -c 5000 /dev/zero | tr '\0' a)
for bad in 'not json' '{}' "$long" "$(req stop cron)" "$(req restart agentd)" "$(req restart agentd-broker)" "$(req restart agentos-debug)" \
	"$(req restart ../cron)" '{"op":"service.restart","unit":"cron.service;reboot","task_id":"t","step":1}' \
	'{"op":"service.restart","unit":"cron.service","task_id":"t","step":1,"approved":true}'; do
	as_agentd $B "$bad" | grep -q '"status":"rejected"' || { r=1; echo "not rejected: $(echo "$bad" | cut -c1-80)"; }
done
[ "$(since cron)" = "$before" ] && [ "$(systemctl show -p MainPID --value agentd)" = "$apid" ] || r=1; check broker_rejects $r

before=$(since cron); as_agentd $B "$(req restart cron)" | grep -q '"status":"ok"' && [ "$(since cron)" != "$before" ]; check broker_restart_verified $?
before=$(since NetworkManager); ask_nm; out=$(as_console $AP "{\"id\":$ID}" yes); wait $NMP
echo "$out" | grep -q 'Wi-Fi' && grep -q '"status":"ok"' /run/nm.out && [ "$(since NetworkManager)" != "$before" ]; check broker_approval_allowed $?
before=$(since NetworkManager); ask_nm; as_console $AP "{\"id\":$ID}" no >/dev/null; wait $NMP
grep -q '"status":"denied"' /run/nm.out && [ "$(since NetworkManager)" = "$before" ]; check broker_approval_refused $?
before=$(since NetworkManager); ask_nm; wait $NMP
grep -q '"status":"denied"' /run/nm.out && grep -q 'nobody answered' /run/nm.out && [ "$(since NetworkManager)" = "$before" ]; check broker_approval_timeout $?
before=$(since NetworkManager); ask_nm; kill $NMP; sleep 1; wait $NMP 2>/dev/null
tail -n 1 $AUD | grep -q '"phase":"cancelled"' && [ "$(since NetworkManager)" = "$before" ]; check broker_hangup_cancels $?
as_agentd $B "$(req restart cron)" | grep -q '"status":"ok"' && as_agentd $B "$(req restart cron)" | grep -q '"status":"ok"' &&
	as_agentd $B "$(req restart cron)" | grep -q 'too many times'; check broker_rate_limit $?
r=0; for p in requested rejected approved denied cancelled started verified; do grep -q "\"phase\":\"$p\"" $AUD || { r=1; echo "no audit phase $p"; }; done
[ "$(stat -c '%a %U' $AUD)" = "640 root" ] || r=1; check broker_audit $r

if [ -e /mnt/seed/gemini.env ]; then
	install -m 600 /mnt/seed/gemini.env /etc/agentd/gemini.env
	systemctl restart agentd; active
	# QEMU user-mode DNS sometimes answers late; the offline path is checked above, so wait for it here.
	for _ in $(seq 30); do getent hosts generativelanguage.googleapis.com >/dev/null && break; sleep 1; done
	out=$(agentd ask "Upper-case the text: hello agentos"); rc=$?
	echo "$out"
	[ $rc = 0 ] && echo "$out" | grep -q WORKFLOW_COMPLETE && echo "$out" | grep -q '"source":"live"'; check live_task_verified $?
	out=$(console "Upper-case the text: console works"); rc=$?
	echo "$out"
	[ $rc = 0 ] && echo "$out" | grep -q "Done: 1 step(s) verified" && echo "$out" | grep -q "CONSOLE WORKS"; check console_live $?
	out=$(agentd ask "Restart the systemd-timesyncd service"); rc=$?
	echo "$out"
	[ $rc = 0 ] && echo "$out" | grep STEP_VERIFIED | grep -q '"action":"broker"'; check live_broker_restart $?
	out=$(console "Restart the NetworkManager service" yes); rc=$?
	echo "$out"
	[ $rc = 0 ] && echo "$out" | grep -q "needs your approval" && echo "$out" | grep -q "Restarted NetworkManager"; check console_approval $?
	key=$(sed -n 's/^GEMINI_API_KEY=//p' /etc/agentd/gemini.env)
	! journal | grep -qF "$key" && ! journalctl -b -o cat --no-pager | grep -qF "$key"; check key_not_logged $?
fi
[ $failed = 0 ] || { echo "dns from the guest:"; getent ahosts generativelanguage.googleapis.com | head -3; resolvectl status 2>&1 | grep -E "DNS Server|Current" ; systemctl status --no-pager agentd agentd-console; journalctl -b --no-pager -o short-monotonic -u agentd -u agentd-console -u agentd-broker | tail -40; }
echo "GUEST_DONE"
GUEST
xorriso -as mkisofs -quiet -V cidata -J -r -o "$S/seed.iso" "$S/user-data" "$S/meta-data" "$S/guest.sh" "$S/agentd.deb" "$ROOT/tests/brokerclient.py" \
	$( [ -e "$S/gemini.env" ] && echo "$S/gemini.env" ) 2>/dev/null

timeout -s KILL 300 qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -smp 2 -snapshot -nographic -no-reboot \
	-drive file="$IMG",if=virtio,format=qcow2 -drive file="$S/seed.iso",media=cdrom,readonly=on \
	-nic user,model=virtio-net-pci -serial file:"$O/console.log" -serial file:"$O/serial.log" -monitor none -display none >/dev/null 2>&1 || true

tr -d '\r' <"$O/serial.log" | grep -vE "^\\s*$" || true
fail=0
for c in $EXPECT; do
	tr -d '\r' <"$O/serial.log" | grep -qx "CHECK $c ok" || { echo "missing or failed: $c" >&2; fail=1; }
done
exit $fail

#!/bin/sh
# Debian base, chunk 5: proves config.set_ntp (the broker's one modifying operation) is a transaction. Boots the stock
# Debian 13 cloud image in a throwaway KVM guest -- on a qcow2 overlay, so the base image is never written, but the
# guest's own disk survives a reboot, which -snapshot would not allow -- installs build/deb/agentd_*.deb and then:
#   boot 1: the plain path, repeats, rejected values, a failed postcondition rolled back, every interrupted on-disk
#           stage recovered by agentd-broker-recover, SIGKILL during real changes, and no space for the journal;
#   boot 2: the recovery at boot that a crash before the commit must trigger, before systemd-timesyncd reads the file;
#   then CUTS (default 2) power cuts: QEMU is killed mid-change and the guest is booted again.
# Prints one "CHECK <name> ok|fail" line per check; exits 0 iff all expected checks are ok and none failed.
# No crash points exist in the binary: the stages are crafted on disk and the interruptions are real kills.
# Needs scripts/fetch-debian-cloud.sh and scripts/build-deb.sh. No key and no network service are used.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMG=$ROOT/build/debian-cloud/debian-13-genericcloud-amd64.qcow2
DEB=$(ls "$ROOT"/build/deb/agentd_*_amd64.deb)
CUTS=${CUTS:-2}
O=$ROOT/build/txn-vm
mkdir -p "$O"
S=$(mktemp -d "$O/run.XXXXXX")
QP=
cleanup() { [ -z "$QP" ] || kill -9 "$QP" 2>/dev/null; rm -rf "$S"; }
trap cleanup EXIT INT TERM
umask 077

EXPECT="set_ntp_verified set_ntp_again set_ntp_rejects set_ntp_rollback recover_no_journal recover_before_write
	recover_after_write recover_new_file_removed recover_after_kill set_ntp_no_space recover_at_boot recover_unit_ok
	consistent_after_power_cut set_ntp_after_power_cut"

cp "$DEB" "$S/agentd.deb"
cp "$ROOT/tests/brokerclient.py" "$S/brokerclient.py"
echo "$CUTS" >"$S/cuts"
printf 'instance-id: agentd-txn\nlocal-hostname: agentd-txn\n' >"$S/meta-data"
cat >"$S/user-data" <<'UD'
#cloud-config
runcmd:
  - [sh, -c, "mkdir -p /mnt/seed && mount -o ro /dev/disk/by-label/cidata /mnt/seed && sh /mnt/seed/phase.sh"]
UD

cat >"$S/phase.sh" <<'GUEST'
# Runs as root in the guest: from cloud-init on the first boot, from txnphase.service on every later one.
# Results go to the second serial port (ttyS0 is the console, reset by its getty).
exec >/dev/ttyS1 2>&1
set -u
V=/var/lib/txnphase
B=/run/agentd-broker.sock
NC=/etc/systemd/timesyncd.conf.d/50-agentd-ntp.conf
TXN=/var/lib/agentd-broker/txn
AUD=/var/log/agentd-broker/audit.jsonl
BASE=$V/base         # the committed copy of $NC that a rollback must restore
SERVERS='time\.cloudflare\.com|time\.google\.com|pool\.ntp\.org|in\.pool\.ntp\.org'
failed=0
check() { if [ "$2" = 0 ]; then echo "CHECK $1 ok"; else echo "CHECK $1 fail"; failed=1; fi; }
bc() { python3 $V/brokerclient.py "$@"; }
ntp() { bc $B "{\"op\":\"config.set_ntp\",\"unit\":\"systemd-timesyncd.service\",\"task_id\":\"txn\",\"step\":1,\"value\":\"$1\"}"; }
poke() { bc $B '{"op":"service.status","unit":"cron.service","task_id":"txn","step":1}'; }
loaded() { timedatectl show-timesync --property=SystemNTPServers --value; }
# The broker allows three changes per unit per 10 minutes, counted in memory: stopping it clears that for the next test.
clear_limit() { systemctl stop agentd-broker.service 2>/dev/null
	systemctl reset-failed agentd-broker.service agentd-broker.socket systemd-timesyncd.service 2>/dev/null; }
# Either there is no drop-in, or it is exactly the one the broker writes, naming a server from its list.
conf_ok() { [ ! -e $NC ] || { [ "$(wc -l <$NC)" = 3 ] && grep -qE "^NTP=($SERVERS)\$" $NC && [ "$(stat -c %a $NC)" = 644 ]; }; }
settled() { conf_ok && [ ! -e $TXN ] && [ ! -e $NC.agentd-tmp ]; }
# An interrupted transaction, as it would be left on disk: journalled, with $BASE as the backup of $NC.
stage() { install -d -m 700 $TXN; install -m 644 $BASE $TXN/0; printf '[["%s",true]]' $NC >$TXN/journal.json; sync; }
recover_now() { systemctl restart agentd-broker-recover.service; }

if [ ! -e $V/n ]; then
	mkdir -p $V
	cp /mnt/seed/brokerclient.py /mnt/seed/cuts $V/
	cp /mnt/seed/phase.sh /usr/local/sbin/txnphase
	cat >/etc/systemd/system/txnphase.service <<'UNIT'
[Unit]
Description=config.set_ntp transaction test, one phase per boot
After=agentd-broker-recover.service systemd-timesyncd.service agentd.service cron.service
[Service]
Type=oneshot
ExecStart=/bin/sh /usr/local/sbin/txnphase
[Install]
WantedBy=multi-user.target
UNIT
	apt-get update -q >/dev/null 2>&1
	apt-get install -y -q systemd-timesyncd /mnt/seed/agentd.deb >/dev/null 2>&1
	systemctl unmask -q systemd-timesyncd.service 2>/dev/null
	systemctl start systemd-timesyncd.service cron.service
	systemctl enable -q txnphase.service
	echo 0 >$V/n
fi
n=$(cat $V/n)
cuts=$(cat $V/cuts)
done_cuts=$(cat $V/done_cuts 2>/dev/null || echo 0)

if [ "$n" = 0 ]; then
	[ "$(systemctl show -p LoadState --value systemd-timesyncd.service)" = loaded ] || { echo "CHECK timesyncd_present fail"; failed=1; }

	ntp pool.ntp.org | grep -q '"status":"ok"' && grep -q '^NTP=pool.ntp.org$' $NC &&
		[ "$(loaded)" = pool.ntp.org ] && settled; check set_ntp_verified $?
	cp $NC $BASE
	ntp pool.ntp.org | grep -q '"status":"ok"' && cmp -s $BASE $NC && settled; check set_ntp_again $?

	r=0
	for bad in '"ntp.example.com"' '"pool.ntp.org "' '"pool.ntp.org\nNTP=ntp.example.com"' 'null' '["pool.ntp.org"]' '1'; do
		bc $B "{\"op\":\"config.set_ntp\",\"unit\":\"systemd-timesyncd.service\",\"task_id\":\"t\",\"step\":1,\"value\":$bad}" |
			grep -q '"status":"rejected"' || { r=1; echo "not rejected: $bad"; }
	done
	bc $B '{"op":"config.set_ntp","unit":"cron.service","task_id":"t","step":1,"value":"pool.ntp.org"}' | grep -q '"status":"rejected"' || r=1
	cmp -s $BASE $NC && [ ! -e $TXN ] || r=1; check set_ntp_rejects $r

	# A real failure after the file was written: the unit is still loaded, so the change goes ahead, but
	# systemd-timesyncd cannot come back. The daemon's answer is what decides, so this must be rolled back.
	clear_limit
	install -d /etc/systemd/system/systemd-timesyncd.service.d
	printf '[Service]\nExecStartPre=/bin/false\n' >/etc/systemd/system/systemd-timesyncd.service.d/fail.conf
	systemctl daemon-reload
	out=$(ntp time.google.com)
	rm -rf /etc/systemd/system/systemd-timesyncd.service.d
	systemctl daemon-reload; systemctl reset-failed systemd-timesyncd.service; systemctl start systemd-timesyncd.service
	echo "$out"
	echo "$out" | grep -q '"status":"failed"' && echo "$out" | grep -q 'previous setting is back' &&
		cmp -s $BASE $NC && [ "$(stat -c %a $NC)" = 644 ] && [ ! -e $TXN ] &&
		grep -q '"phase":"rolled_back"' $AUD; check set_ntp_rollback $?

	# Every on-disk stage an interrupted transaction can be caught in, recovered by the unit that runs at boot.
	r=0; install -d -m 700 $TXN; recover_now || r=1
	{ [ ! -e $TXN ] && cmp -s $BASE $NC; } || r=1; check recover_no_journal $r

	r=0; stage; recover_now || r=1
	{ [ ! -e $TXN ] && cmp -s $BASE $NC && [ "$(stat -c %a $NC)" = 644 ]; } || r=1; check recover_before_write $r

	r=0; stage; printf '[Time]\nNTP=time.goo' >$NC.agentd-tmp
	printf '[Time]\nNTP=time.google.com\n' >$NC; chmod 600 $NC; sync; recover_now || r=1
	{ settled && cmp -s $BASE $NC; } || r=1; check recover_after_write $r

	r=0; install -d -m 700 $TXN; printf '[["%s",false]]' $NC >$TXN/journal.json; sync; recover_now || r=1
	{ [ ! -e $TXN ] && [ ! -e $NC ]; } || r=1; check recover_new_file_removed $r
	install -m 644 $BASE $NC

	# Real interruptions: SIGKILL somewhere inside a change, then the next request, which is answered only after
	# the broker has recovered. Whatever stage it hit, the file is either the old one or a whole new one.
	r=0
	for i in 1 2 3 4 5 6 7 8; do
		clear_limit; systemctl reset-failed systemd-timesyncd.service 2>/dev/null
		ntp time.google.com >/dev/null 2>&1 &
		sleep "0.$(od -An -N2 -tu2 /dev/urandom | tr -d ' \n' | awk '{printf "%03d", $1 % 400}')"
		kill -9 "$(systemctl show -p MainPID --value agentd-broker.service)" 2>/dev/null
		wait 2>/dev/null
		systemctl reset-failed agentd-broker.service agentd-broker.socket 2>/dev/null
		poke >/dev/null 2>&1
		settled || { r=1; echo "kill $i left: $(tr '\n' ' ' <$NC 2>/dev/null) txn=$(ls -A $TXN 2>/dev/null)"; }
		systemctl is-active -q systemd-timesyncd.service || systemctl start systemd-timesyncd.service
	done
	install -m 644 $BASE $NC; check recover_after_kill $r

	# No room for the write-ahead backup: the change must not start. A tiny tmpfs over the state directory is the
	# shortcut: it reproduces ENOSPC on the journal without filling the guest's root filesystem.
	clear_limit
	mount -t tmpfs -o size=4k,nr_inodes=1 tmpfs /var/lib/agentd-broker
	out=$(ntp time.google.com); echo "$out"
	umount /var/lib/agentd-broker; clear_limit
	echo "$out" | grep -q '"status":"failed"' && cmp -s $BASE $NC && [ ! -e $TXN ]; check set_ntp_no_space $?

	# Leave a transaction open, interrupted after the new file was written: the next boot must undo it before
	# systemd-timesyncd reads it.
	stage; printf '[Time]\nNTP=time.google.com\n' >$NC
	echo 1 >$V/n; sync
	echo PHASE0_DONE
	systemctl poweroff
	exit 0
fi

if [ "$n" = 1 ]; then
	{ [ ! -e $TXN ] && cmp -s $BASE $NC && [ "$(stat -c %a $NC)" = 644 ] && [ "$(loaded)" = pool.ntp.org ] &&
		grep -q '"phase":"recovered"' $AUD; }; check recover_at_boot $?
	[ "$(systemctl show -p ExecMainStatus --value agentd-broker-recover.service)" = 0 ] &&
		[ "$(systemctl show -p Result --value agentd-broker-recover.service)" = success ]; check recover_unit_ok $?
	echo 2 >$V/n; sync
fi

# Phase 2: after each power cut. The guest is consistent, recovered, and still able to make the change.
if [ "$n" = 2 ]; then
	{ settled && systemctl is-active -q systemd-timesyncd.service &&
		[ ! -e $TXN ]; }; check consistent_after_power_cut $?
	clear_limit
	ntp in.pool.ntp.org | grep -q '"status":"ok"' && [ "$(loaded)" = in.pool.ntp.org ] && settled
	check set_ntp_after_power_cut $?
	cp $NC $BASE
fi

if [ "$done_cuts" -lt "$cuts" ]; then
	echo $((done_cuts + 1)) >$V/done_cuts
	echo 2 >$V/n; sync
	echo CUT_NOW
	# Real changes, back to back, for the host to pull the plug into.
	while :; do
		clear_limit; ntp time.google.com >/dev/null 2>&1
		clear_limit; ntp pool.ntp.org >/dev/null 2>&1
	done
fi
[ $failed = 0 ] || { journalctl -b --no-pager -o short-monotonic -u agentd-broker -u agentd-broker-recover | tail -40; cat $AUD | tail -20; }
echo GUEST_DONE
systemctl poweroff
GUEST

xorriso -as mkisofs -quiet -V cidata -J -r -o "$S/seed.iso" \
	"$S/user-data" "$S/meta-data" "$S/phase.sh" "$S/agentd.deb" "$S/brokerclient.py" "$S/cuts" 2>/dev/null
qemu-img create -q -f qcow2 -F qcow2 -b "$IMG" "$S/disk.qcow2" 20G

boot() { # $1 = this boot's serial log
	qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -smp 2 -nographic -no-reboot \
		-drive file="$S/disk.qcow2",if=virtio,format=qcow2 -drive file="$S/seed.iso",media=cdrom,readonly=on \
		-nic user,model=virtio-net-pci -serial file:"$S/console.log" -serial file:"$1" -monitor none -display none \
		>/dev/null 2>&1 &
	QP=$!
}
# Echoes the marker this boot reached, or nothing if it reached none within $2 seconds.
marker() {
	i=0
	while [ $i -lt "$((${2} * 5))" ]; do
		m=$(tr -d '\r' <"$1" 2>/dev/null | grep -oE '(PHASE0_DONE|CUT_NOW|GUEST_DONE)' | tail -1)
		[ -z "$m" ] || { echo "$m"; return 0; }
		kill -0 "$QP" 2>/dev/null || return 1
		sleep 0.2
		i=$((i + 1))
	done
	return 1
}

b=0
while [ $b -lt $((CUTS + 4)) ]; do
	b=$((b + 1))
	L=$S/serial-$b.log
	: >"$L"
	boot "$L"
	m=$(marker "$L" 420) || { echo "no marker on boot $b" >&2; kill -9 "$QP" 2>/dev/null; break; }
	case $m in
	CUT_NOW)
		d=$(awk 'BEGIN{srand();printf "%.2f", 0.2 + rand() * 3}')
		sleep "$d"
		kill -9 "$QP" 2>/dev/null
		echo "host: power cut after ${d}s of changes (boot $b)"
		;;
	GUEST_DONE) wait "$QP" 2>/dev/null || true; QP=; break ;;
	*) wait "$QP" 2>/dev/null || true ;;
	esac
	wait "$QP" 2>/dev/null || true
	QP=
done

cat "$S"/serial-*.log 2>/dev/null | tr -d '\r' | grep -vE "^\s*$" >"$O/serial.log" || true
cat "$O/serial.log"
fail=0
grep -q "CHECK .* fail" "$O/serial.log" && fail=1
for c in $EXPECT; do
	grep -qx "CHECK $c ok" "$O/serial.log" || { echo "missing or failed: $c" >&2; fail=1; }
done
exit $fail

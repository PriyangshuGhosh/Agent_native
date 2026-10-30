#!/bin/sh
# Debian base, step 3: boots build/debian-img/cua-agentos-amd64.img (scripts/build-debian-img.sh) in a throwaway KVM
# guest: UEFI (OVMF) -> systemd-boot -> Debian, from a sparse copy that is deleted on exit (plus -snapshot), user-mode
# NAT, a virtio GPU as the screen, USB keyboard and tablet. The key file (GEMINI_KEY_FILE, default ./GEMINI_API_KEY.env)
# goes onto the copy's FAT partition exactly as a user would put it on the card. A request is typed on the screen
# through the QEMU monitor, and the console joins a simulated Wi-Fi network (mac80211_hwsim; the access point runs in
# its own network namespace). Prints one "CHECK <name> ok|fail" line per check; exits 0 iff all expected checks are ok.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMG=$ROOT/build/debian-img/cua-agentos-amd64.img
KEY_FILE=${GEMINI_KEY_FILE:-$ROOT/GEMINI_API_KEY.env}
O=$ROOT/build/debian-img-vm
mkdir -p "$O"
S=$(mktemp -d "$O/run.XXXXXX")
trap 'rm -rf "$S"' EXIT INT TERM
umask 077

cp --sparse=always "$IMG" "$S/disk.img"
cp /usr/share/OVMF/OVMF_VARS_4M.fd "$S/vars.fd"
EXPECT="systemd_pid1 root_locked agentd_active kiosk_on_screen input_devices typed_on_screen wifi_wrong_password
	wifi_joined wifi_saved_root_only bootlog_on_fat timesync_on_network_up debug_wrong_pin debug_wrong_token debug_command debug_journal"
ESP="$S/disk.img@@1M"
export MTOOLS_SKIP_CHECK=1
if [ -r "$KEY_FILE" ]; then
	cp "$KEY_FILE" "$S/gemini.env"
	mcopy -i "$ESP" "$S/gemini.env" ::/gemini.env
	EXPECT="$EXPECT key_imported live_typed_task clock_wait_recovers read_tool_date chat_reply chat_not_logged key_not_logged"
fi
# Debug link: the server runs here, reached from the guest as 10.0.2.2 (QEMU user-mode NAT).
export DEBUG_DIR="$S/debug"
mkdir "$S/fat"
"$ROOT/scripts/debug-server.py" card "$S/fat" --ip 10.0.2.2
mcopy -i "$ESP" "$S/fat/agentos-debug.env" ::/agentos-debug.env
"$ROOT/scripts/debug-server.py" serve --bind 127.0.0.1 >/dev/null & SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$S"' EXIT INT TERM
mtype -i "$ESP" ::/loader/entries/agentos.conf | sed '/^options/s|$| systemd.run=/boot/firmware/guest.sh|' >"$S/entry.conf"
mcopy -o -i "$ESP" "$S/entry.conf" ::/loader/entries/agentos.conf

cat >"$S/guest.sh" <<'GUEST'
#!/bin/sh
# Runs as root in the guest (systemd.run=); results go to the second serial port.
exec >/dev/ttyS1 2>&1
systemctl start multi-user.target # systemd.run= boots into its own unit only
failed=0
check() { if [ "$2" = 0 ]; then echo "CHECK $1 ok"; else echo "CHECK $1 fail"; failed=1; fi; }
upto() { n=$1; shift; for _ in $(seq "$n"); do "$@" && return 0; sleep 1; done; return 1; }
journal() { journalctl -b -u agentd -o cat --no-pager; }
console_up() { pgrep -u agentos -f '^/usr/bin/agentd console' >/dev/null; }

[ "$(cat /proc/1/comm)" = systemd ]; check systemd_pid1 $?
[ "$(passwd -S root | cut -d' ' -f2)" = L ]; check root_locked $?
upto 30 systemctl is-active -q agentd; check agentd_active $?

upto 60 console_up; sleep 3
cage=$(pgrep -u agentos -x cage); con=$(pgrep -u agentos -f '^/usr/bin/agentd console')
systemctl is-active -q agentos-kiosk && pgrep -u agentos -x foot >/dev/null && [ -n "$cage" ] &&
	readlink /proc/"$con"/fd/0 | grep -q '^/dev/pts/'; check kiosk_on_screen $?
# Detection only: cage (libinput) holds the USB keyboard and tablet open.
[ "$(ls -l /proc/"$cage"/fd | grep -c '/dev/input/event')" -ge 2 ]; check input_devices $?

if [ -e /etc/agentd/gemini.env ]; then
	[ ! -e /boot/firmware/gemini.env ] && [ "$(stat -c %a:%U /etc/agentd/gemini.env)" = 600:root ] &&
		journal | grep AGENTD_READY | grep -q '"planner":"live"'; check key_imported $?
fi
mark=$(date +%s)
echo TYPE_NOW
typed() { journalctl -b -u agentd -o cat --no-pager --since "@$mark" | grep -q TASK_COMPLETE; }
upto 90 typed; check typed_on_screen $?
if [ -e /etc/agentd/gemini.env ]; then
	journalctl -b -u agentd -o cat --no-pager --since "@$mark" | grep STEP_VERIFIED | grep -q 'TYPED ON SCREEN'
	check live_typed_task $?
fi

journalctl -b -u systemd-timesyncd -o cat --no-pager | grep -q Stopping; check timesync_on_network_up $?

# Debug link: the pin and the token are both enforced.
dbg() { sed -n "s/^$1=//p" /boot/firmware/agentos-debug.env; }
curl -k --pinnedpubkey sha256//AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= -s -o /dev/null --max-time 10 "$(dbg DEBUG_URL)/next"
[ $? = 90 ]; check debug_wrong_pin $?
[ "$(curl -k --pinnedpubkey "sha256//$(dbg DEBUG_PIN)" -s -o /dev/null -w '%{http_code}' --max-time 10 "$(dbg DEBUG_URL)/next")" = 403 ]; check debug_wrong_token $?

# A board with no battery clock: certificates look "not yet valid" until internet time arrives, and the task waits for it.
if [ -e /etc/agentd/gemini.env ]; then
	systemctl stop systemd-timesyncd; rm -f /run/systemd/timesync/synchronized; date -s 2020-01-01 >/dev/null
	agentd ask 'Upper-case the text: clock test' >/run/clock.out 2>&1 & ask=$!
	waiting() { grep -q CLOCK_WAIT /run/clock.out; }
	upto 30 waiting; waited=$?
	systemctl start systemd-timesyncd
	wait $ask; asked=$?
	cat /run/clock.out | cut -c1-200
	[ $waited = 0 ] && [ $asked = 0 ] && grep -q 'CLOCK TEST' /run/clock.out; check clock_wait_recovers $?
	agentd ask 'Print the current date' >/run/date.out 2>&1
	grep STEP_VERIFIED /run/date.out | grep '"action":"read"' | grep -q "$(date +%Y)"; check read_tool_date $?
	agentd ask 'Hello! Please reply with the word pineapple-seven.' >/run/chat.out 2>&1
	grep CHAT_REPLY /run/chat.out | grep -q 'gemini' && grep -qi pineapple-seven /run/chat.out; check chat_reply $?
	! journalctl -b -o cat --no-pager | grep -qi pineapple-seven; check chat_not_logged $?
fi

# Wi-Fi: test-only tools (never in the image), one simulated radio for NetworkManager, the other as the access point.
upto 30 getent hosts deb.debian.org >/dev/null
apt-get update -q >/dev/null 2>&1; apt-get install -y -q iw hostapd dnsmasq-base >/dev/null 2>&1 || echo "apt-get install failed"
modprobe mac80211_hwsim radios=2 && upto 10 test -e /sys/class/net/wlan1
ip netns add ap && iw phy "$(basename "$(readlink /sys/class/net/wlan1/phy80211)")" set netns name ap
printf 'interface=wlan1\ndriver=nl80211\nssid=agentos-test\nhw_mode=g\nchannel=6\nwpa=2\nwpa_passphrase=correct-horse-9\nwpa_key_mgmt=WPA-PSK\nrsn_pairwise=CCMP\n' >/run/ap.conf
ip netns exec ap sh -c 'ip link set lo up; ip link set wlan1 up; ip addr add 10.77.0.1/24 dev wlan1
	hostapd -B /run/ap.conf >/dev/null; dnsmasq --interface=wlan1 --bind-interfaces --port=0 --dhcp-range=10.77.0.10,10.77.0.50,1h'
seen() { nmcli dev wifi rescan >/dev/null 2>&1; nmcli -t -f SSID dev wifi list | grep -qx agentos-test; }
upto 30 seen || echo "access point not seen"
out=$(printf 'wifi\nagentos-test\nwrong-password-1\nwifi\nagentos-test\ncorrect-horse-9\n' | runuser -u agentos -- agentd console)
echo "$out"
echo "$out" | grep -q 'Could not join agentos-test' && echo "$out" | grep -q 'Nothing was saved'; check wifi_wrong_password $?
echo "$out" | grep -q 'Connected to agentos-test' && nmcli -t -f NAME,DEVICE con show --active | grep -qx agentos-test:wlan0 &&
	ip -4 addr show wlan0 | grep -q 'inet 10.77.0.'; check wifi_joined $?
f=$(grep -l '^ssid=agentos-test' /etc/NetworkManager/system-connections/* 2>/dev/null)
[ "$(echo "$f" | grep -c .)" = 1 ] && [ "$(stat -c %a:%U "$f")" = 600:root ] &&
	! journalctl -b -o cat --no-pager | grep -q -e correct-horse-9 -e wrong-password-1; check wifi_saved_root_only $?

systemctl start agentos-bootlog.service && grep -q 'agentos-kiosk' /boot/firmware/agentos-journal.txt; check bootlog_on_fat $?
if [ -e /etc/agentd/gemini.env ]; then
	key=$(sed -n 's/^GEMINI_API_KEY=//p' /etc/agentd/gemini.env)
	! journalctl -b -o cat --no-pager | grep -qF "$key" && ! grep -qF "$key" /boot/firmware/agentos-journal.txt; check key_not_logged $?
fi
[ $failed = 0 ] || { systemctl --failed --no-pager; journalctl -b --no-pager -o short-monotonic -u agentd -u agentos-kiosk -u NetworkManager | tail -60; }
echo GUEST_DONE
systemctl poweroff
GUEST
mcopy -i "$ESP" "$S/guest.sh" ::/guest.sh

# Typed on the virtual keyboard once the guest says the console is up: "Upper-case the text: typed on screen" + Enter.
KEYS="shift-u p p e r minus c a s e spc t h e spc t e x t shift-semicolon spc t y p e d spc o n spc s c r e e n ret"
: >"$O/serial.log"
(
	for _ in $(seq 240); do grep -q TYPE_NOW "$O/serial.log" 2>/dev/null && break; sleep 1; done
	if [ "$("$ROOT/scripts/debug-server.py" send 'id -u; cat /proc/1/comm' --wait 30 | tr '\n' ' ')" = "0 systemd " ]; then echo "CHECK debug_command ok"; else echo "CHECK debug_command fail"; fi >"$S/host.checks"
	grep -q 'agentos-kiosk' "$DEBUG_DIR/pi.log" && echo "CHECK debug_journal ok" >>"$S/host.checks" || echo "CHECK debug_journal fail" >>"$S/host.checks"
	python3 -I -c 'import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
for k in sys.argv[2].split():
    s.sendall(b"sendkey %s\n" % k.encode()); time.sleep(0.08)
time.sleep(0.5)' "$S/mon" "$KEYS"
) & KEYS_PID=$!
timeout -s KILL 300 qemu-system-x86_64 -enable-kvm -cpu host -m 2048 -smp 2 -snapshot -no-reboot \
	-drive if=pflash,format=raw,readonly=on,file=/usr/share/OVMF/OVMF_CODE_4M.fd -drive if=pflash,format=raw,file="$S/vars.fd" \
	-drive file="$S/disk.img",if=virtio,format=raw -nic user,model=virtio-net-pci \
	-vga none -device virtio-gpu-pci -device qemu-xhci -device usb-kbd -device usb-tablet -display none \
	-serial file:"$O/console.log" -serial file:"$O/serial.log" -monitor unix:"$S/mon",server,nowait >/dev/null 2>&1 || true
wait $KEYS_PID

cat "$S/host.checks" >>"$O/serial.log"
tr -d '\r' <"$O/serial.log" | grep -vE '^\s*$' || true
fail=0
for c in $EXPECT; do
	tr -d '\r' <"$O/serial.log" | grep -qx "CHECK $c ok" || { echo "missing or failed: $c" >&2; fail=1; }
done
exit $fail

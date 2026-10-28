#!/bin/sh
# Persistent /data test (not a cycle gate). Boots the Cycle 06 image three times with one ext4 disk labelled agentos-data,
# which the initramfs mounts as the overlay upper (so /data/registry.json and installed capabilities persist):
#   every boot: QEMU exits 0, the disk is left clean (no ext4 needs_recovery: agent-init remounted it read-only), every
#           TASK_COMPLETE is a success and TIER3_PASS is emitted (last boot's editor session must not be restored)
#   boot 1 (blank disk): STORAGE_READY {persistent:true, upper:"ext4"}; lifecycle TASK_START installed == []; the
#           lifecycle succeeds with registry ["test-cap"]
#   boot 2: TASK_START installed == ["test-cap"] (registry and binary survived the reboot); lifecycle succeeds again
#   boot 3: debugfs first plants a transaction cut short by a crash (journal says /usr/local/bin/ghost-cap was new, and
#           the half-installed file is there); agentd must roll it back at start: CAPABILITY_ROLLBACK + ROLLBACK_VERIFIED
#           {package:"ghost-cap", clean:true} before TASK_START, which still shows installed == ["test-cap"]
# Needs scripts/build-rootfs-06.sh first.
set -eu
[ -n "${GATE_INNER:-}" ] || GATE_INNER=1 exec timeout -s KILL 300 "$0" "$@"

ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=${ROOTFS_DIR:-$ROOT/build/rootfs-06}
DISK=$ROOT/build/persist-data.img
for f in "$B/vmlinuz" "$B/initramfs" "$B/rootfs.squashfs"; do
	[ -f "$f" ] || { echo "test-persist: missing $f (run scripts/build-rootfs-06.sh)" >&2; exit 2; }
done
rm -f "$DISK"
/usr/sbin/mke2fs -q -t ext4 -L agentos-data "$DISK" 64M

fail=0
boot() {  # boot <n>: boots once, leaves the telemetry in $EVENTS
	log=$ROOT/build/persist-$1-serial.log
	: >"$log"
	rc=0
	timeout -s KILL 80 qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp 2 \
		-display none -monitor none -nic none -no-reboot \
		-kernel "$B/vmlinuz" -initrd "$B/initramfs" -append "console=ttyS0 quiet loglevel=0 panic=0" \
		-drive "file=$B/rootfs.squashfs,if=virtio,format=raw,readonly=on" \
		-drive "file=$DISK,if=virtio,format=raw" \
		-serial "file:$log" </dev/null >/dev/null 2>&1 || rc=$?
	[ "$rc" -eq 0 ] || { echo "test-persist: FAIL boot $1: qemu exit $rc" >&2; fail=1; }
	# agent-init must leave the ext4 upper clean at power-off; a pending journal replay would also undo boot 3's plant.
	if /usr/sbin/dumpe2fs -h "$DISK" 2>/dev/null | grep -q '^Filesystem features:.*needs_recovery'; then
		echo "test-persist: FAIL boot $1: data disk left needing journal recovery (not remounted read-only)" >&2; fail=1
	fi
	EVENTS=$(jq -cR 'fromjson? | objects | select((.ts_ms|type)=="number" and (.event|type)=="string")' "$log")
}
check() {  # check <name> <jq program over the event array>; $start = index of the lifecycle TASK_START
	printf '%s\n' "$EVENTS" | jq -e -s "(map(.event==\"TASK_START\" and .task_id==\"t06-lifecycle\") | index(true)) as \$start | $2" \
		>/dev/null || { echo "test-persist: FAIL $1" >&2; fail=1; }
}
storage='any(.[]; .event=="STORAGE_READY" and .persistent==true and .upper=="ext4" and .overlay==true and .base_ro==true)'
# Every task succeeds and Tier 3 still finds a fresh editor: app state is per-boot scratch, not carried on the disk.
done_ok='any(.[]; .event=="TASK_COMPLETE" and .task_id=="t06-lifecycle" and .status=="success" and .registry==["test-cap"])
	and all(.[]; .event!="TASK_COMPLETE" or .status=="success") and any(.[]; .event=="TIER3_PASS")'

boot 1
check boot1_storage "$storage"
check boot1_fresh   '$start != null and .[$start].installed == []'
check boot1_done    "$done_ok"

boot 2
check boot2_storage  "$storage"
check boot2_survived '$start != null and .[$start].installed == ["test-cap"]'
check boot2_no_recovery 'all(.[]; .event != "ROLLBACK_VERIFIED" or .package != "ghost-cap")'
check boot2_done     "$done_ok"

# Plant the crashed transaction straight into the persistent upper layer.
T=$ROOT/build/persist-txn
rm -rf "$T" && mkdir -p "$T"
printf '[["/usr/local/bin/ghost-cap",false]]' >"$T/journal.json"
printf 'ghost-cap' >"$T/package"
printf '#!/bin/sh\necho half-installed\n' >"$T/ghost-cap"
/usr/sbin/debugfs -w "$DISK" -f - >/dev/null 2>&1 <<EOF
mkdir /upper/data/.agentd-txn
write $T/journal.json /upper/data/.agentd-txn/journal.json
write $T/package /upper/data/.agentd-txn/package
write $T/ghost-cap /upper/usr/local/bin/ghost-cap
EOF
rm -rf "$T"

boot 3
check boot3_recovered '(map(.event=="ROLLBACK_VERIFIED" and .package=="ghost-cap" and .clean==true and .restored==true) | index(true)) as $v
	| $v != null and $start != null and $v < $start
	and any(.[:$start][]; .event=="CAPABILITY_ROLLBACK" and .package=="ghost-cap")'
check boot3_installed '$start != null and .[$start].installed == ["test-cap"]'
check boot3_done      "$done_ok"
exit $fail

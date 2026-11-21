#!/bin/sh
# Application layer on Debian 13 in a throwaway KVM guest (qcow2 overlay, deleted on exit; user-mode NAT).
# Installs build/deb/agentd_*.deb plus LibreOffice from Debian, then checks the runner service as systemd runs it:
# identity, socket permissions, a sandboxed capability run by the unit, world state, external changes, and - with a
# key file (GEMINI_KEY_FILE, default ./GEMINI_API_KEY.env) - a live-planned task that creates and converts a document,
# and a live-planned edit applied inside a running LibreOffice that has the document open.
# BLENDER=1 also installs Blender and checks scene creation by script (with approval), a typed edit verified through the
# scene inspector, a render, an edit through the live bridge, and a live-planned scene.
# Prints "CHECK <name> ok|fail"; exits 0 iff every expected check is ok. Needs scripts/fetch-debian-cloud.sh, scripts/build-deb.sh.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
IMG=$ROOT/build/debian-cloud/debian-13-genericcloud-amd64.qcow2
DEB=$(ls "$ROOT"/build/deb/agentd_*_amd64.deb)
KEY_FILE=${GEMINI_KEY_FILE:-$ROOT/GEMINI_API_KEY.env}
O=$ROOT/build/apps-vm
mkdir -p "$O"
S=$(mktemp -d "$O/seed.XXXXXX")
trap 'rm -rf "$S"' EXIT INT TERM
umask 077
cp "$DEB" "$S/agentd.deb"
EXPECT="installed runner_not_root runner_socket_group_only approvals_person_only capability_committed file_owned_by_person state_verified
	context_lists_capabilities external_change_seen bad_path_refused pdf_made"
if [ -r "$KEY_FILE" ]; then
	printf 'GEMINI_API_KEY=%s\n' "$(tr -d ' \r\n' <"$KEY_FILE")" >"$S/gemini.env"
	[ -z "${AGENTD_MODEL:-}" ] || echo "AGENTD_MODEL=$AGENTD_MODEL" >>"$S/gemini.env"
	EXPECT="$EXPECT planned_task_verified planned_files_exist planned_live_edit live_edit_not_saved"
	[ -z "${BLENDER:-}" ] || EXPECT="$EXPECT blender_planned_scene_rendered"
fi
[ -z "${BLENDER:-}" ] || { EXPECT="$EXPECT blender_script_needs_yes blender_scene_created blender_light_verified blender_state_has_structure blender_rendered blender_live_edit"; touch "$S/blender"; }
printf 'instance-id: agentd-apps\nlocal-hostname: agentd-apps\n' >"$S/meta-data"
cat >"$S/user-data" <<'UD'
#cloud-config
runcmd:
  - [sh, -c, "mkdir -p /mnt/seed && mount -o ro /dev/disk/by-label/cidata /mnt/seed && sh /mnt/seed/guest.sh; poweroff"]
UD
cat >"$S/guest.sh" <<'GUEST'
exec >/dev/ttyS1 2>&1
check() { if [ "$2" = 0 ]; then echo "CHECK $1 ok"; else echo "CHECK $1 fail"; fi; }
H=/home/agentos
# agentd's part, played by an unprivileged process that is only in group agentd-apps
client() { setpriv --reuid=nobody --regid=nogroup --groups="$(getent group agentd-apps | cut -d: -f3)" python3 /mnt/seed/appsclient.py "$1"; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -q >/dev/null 2>&1
apt-get install -y -q --no-install-recommends /mnt/seed/agentd.deb libreoffice-writer python3-uno jq >/dev/null 2>&1
# The person (on the image, gnome-initial-setup makes the account and login starts the runner; here, by hand).
useradd -m agentos && export APPS_UID=$(id -u agentos) && systemctl start agentd-apps@$APPS_UID.socket agentd-apps-approve@$APPS_UID.socket
systemctl is-active -q agentd-apps@$APPS_UID.socket && command -v soffice >/dev/null && command -v bwrap >/dev/null; check installed $?

R=$(client '{"op":"run","cap":"libreoffice.create_text","args":{"output":"report.odt","title":"Quarterly report","body":"Sales rose 4 percent."}}'); echo "$R"
printf "%s" "$R" | jq -e '.status=="ok" and .output.state=="committed" and (.output.checks|length==3)' >/dev/null; check capability_committed $?
pid=$(systemctl show -p MainPID --value agentd-apps@$APPS_UID); [ "$pid" -gt 0 ] && [ "$(ps -o user= -p "$pid")" = agentos ]; check runner_not_root $?
! setpriv --reuid=nobody --regid=nogroup --clear-groups python3 /mnt/seed/appsclient.py '{"op":"context"}' >/dev/null 2>&1; check runner_socket_group_only $?
# Approvals: only the person reaches their approval socket (not agentd, not the console group, not other people).
! setpriv --reuid=nobody --regid=nogroup --groups="$(getent group agentd-users | cut -d: -f3),$(getent group agentd-apps | cut -d: -f3)" \
	python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).connect(sys.argv[1])' /run/agentd-apps/$APPS_UID.approve.sock 2>/dev/null
check approvals_person_only $?
[ "$(stat -c %U "$H/report.odt")" = agentos ]; check file_owned_by_person $?
jq -e '."report.odt".status=="verified" and ."report.odt".writer=="agent"' "$H/.agentd/world.json" >/dev/null; check state_verified $?
runuser -u agentos -- sh -c "echo 'my notes' > $H/notes.txt"
C=$(client '{"op":"context"}'); printf "%s" "$C" | jq -r .text | head -30
printf "%s" "$C" | jq -r .text | grep -q 'libreoffice.convert(' && printf "%s" "$C" | jq -r .text | grep -q 'report.odt (verified; agent)'; check context_lists_capabilities $?
printf "%s" "$C" | jq -r .text | grep -q 'created notes.txt'; check external_change_seen $?
client '{"op":"run","cap":"libreoffice.convert","args":{"input":"/etc/shadow","format":"pdf","output":"x.pdf"}}' | grep -q 'not a path inside the workspace'; check bad_path_refused $?
client '{"op":"run","cap":"libreoffice.convert","args":{"input":"report.odt","format":"pdf","output":"report.pdf"}}' | jq -e '.output.state=="committed"' >/dev/null && [ "$(head -c 4 $H/report.pdf)" = "%PDF" ]; check pdf_made $?

if [ -e /mnt/seed/blender ]; then
	apt-get install -y -q --no-install-recommends blender >/dev/null 2>&1
	NEW='{"op":"run","cap":"blender.new_scene","args":{"output":"scene.blend","code":"import bpy\nbpy.ops.mesh.primitive_cube_add(location=(0,0,1))\nbpy.ops.mesh.primitive_plane_add(size=20)\nbpy.ops.object.camera_add(location=(7,-7,5), rotation=(1.1,0,0.785))\nbpy.context.scene.camera=bpy.context.object\n"}}'
	# a script is never run without the person's yes: with nobody answering it is refused (60 s)
	client "$NEW" | grep -q 'not approved' && [ ! -e $H/scene.blend ]; check blender_script_needs_yes $?
	# from here the person says yes at their console (only they can reach their approval socket)
	runuser -u agentos -- python3 /mnt/seed/appsclient.py --approver &
	R=$(client "$NEW"); echo "$R" | cut -c1-600
	printf "%s" "$R" | jq -e '.output.state=="committed"' >/dev/null; check blender_scene_created $?
	R=$(client '{"op":"run","cap":"blender.add_light","args":{"file":"scene.blend","name":"Key","kind":"SUN","x":"4","y":"-4","z":"6","strength":"3"}}'); echo "$R" | cut -c1-600
	printf "%s" "$R" | jq -e '.output.state=="committed" and (.output.checks|index("file: inspect")!=null)' >/dev/null; check blender_light_verified $?
	runuser -u agentos -- env HOME=$H AGENTD_WORKSPACE=$H agentd apps state scene.blend >/run/blend.state 2>&1; head -c 700 /run/blend.state; echo
	jq -e '.status=="verified" and (.structure.data.lights==["Key"]) and (.structure.data.meshes|length==2) and .structure.data.active_camera!=null' /run/blend.state >/dev/null; check blender_state_has_structure $?
	R=$(client '{"op":"run","cap":"blender.render","args":{"input":"scene.blend","output":"scene.png","percent":"10","samples":"4"}}'); echo "$R" | cut -c1-400
	printf "%s" "$R" | jq -e '.output.state=="committed"' >/dev/null && [ "$(head -c 4 $H/scene.png | tail -c 3)" = PNG ]; check blender_rendered $?
	# the person has scene.blend open in Blender (no window here: --background serves the same bridge in a loop)
	runuser -u agentos -- env HOME=$H setsid blender --background $H/scene.blend --python /usr/share/agentd/caps/blender_bridge.py >/run/blender-live.log 2>&1 &
	for _ in $(seq 60); do [ -S "/tmp/agentd-blender-$(id -u agentos).sock" ] && break; sleep 1; done
	before=$(sha256sum <$H/scene.blend)
	R=$(client '{"op":"run","cap":"blender.add_light","args":{"file":"scene.blend","name":"Fill","kind":"AREA","x":"-4","y":"-2","z":"3","strength":"200"}}'); echo "$R" | cut -c1-600
	printf "%s" "$R" | jq -e '.output.state=="applied_live"' >/dev/null && [ "$(sha256sum <$H/scene.blend)" = "$before" ] &&
		jq -e '."scene.blend".live.data.lights==["Key","Fill"] or ."scene.blend".live.data.lights==["Fill","Key"]' $H/.agentd/world.json >/dev/null; check blender_live_edit $?
	pkill -f blender_bridge.py; tail -5 /run/blender-live.log
fi

if [ -r /mnt/seed/gemini.env ]; then
	install -m 600 /mnt/seed/gemini.env /etc/agentd/gemini.env
	systemctl restart agentd
	out=$(agentd ask "Create a text document called plan.odt with the title Trip plan and the body Buy tickets. Then convert plan.odt to a PDF called plan.pdf."); rc=$?
	echo "$out"
	[ $rc = 0 ] && echo "$out" | grep STEP_VERIFIED | grep -q '"action":"app"'; check planned_task_verified $?
	[ "$(head -c 4 $H/plan.pdf)" = "%PDF" ] && python3 /usr/share/agentd/caps/libreoffice_odf.py $H/plan.odt | jq -e '.title=="Trip plan" and (.text|test("Buy tickets"))' >/dev/null; check planned_files_exist $?
	# the person has plan.odt open in LibreOffice (headless here), started the way `agentd apps open` starts it
	runuser -u agentos -- env HOME=$H setsid soffice --headless --norestore --nologo "--accept=pipe,name=agentd-live;urp;" $H/plan.odt >/dev/null 2>&1 &
	for _ in $(seq 60); do [ -S "/tmp/OSL_PIPE_$(id -u agentos)_agentd-live" ] && [ -e "$H/.~lock.plan.odt#" ] && break; sleep 1; done
	before=$(sha256sum <$H/plan.odt)
	out=$(agentd ask "In plan.odt, replace the word tickets with train tickets."); rc=$?
	echo "$out"
	[ $rc = 0 ] && echo "$out" | grep STEP_VERIFIED | grep -q 'applied_live'; check planned_live_edit $?
	[ "$(sha256sum <$H/plan.odt)" = "$before" ] && jq -e '."plan.odt".live.unsaved==true and (."plan.odt".live.data.text|test("train tickets"))' "$H/.agentd/world.json" >/dev/null; check live_edit_not_saved $?
	if [ -e /mnt/seed/blender ]; then
		out=$(agentd ask "Create a 3D scene called room.blend with a cube standing on a large ground plane, a sun light, and a camera that looks at the cube. Then render room.blend to room.png at 10 percent with 4 samples."); rc=$?
		echo "$out" | cut -c1-1500
		[ $rc = 0 ] && [ "$(head -c 4 $H/room.png | tail -c 3)" = PNG ] && runuser -u agentos -- env HOME=$H AGENTD_WORKSPACE=$H agentd apps state room.blend | tee /run/room.state | jq -e '(.structure.data.lights|length>=1) and (.structure.data.meshes|length>=2) and (.structure.data.cameras|length>=1)' >/dev/null; check blender_planned_scene_rendered $?; jq -c .structure.data /run/room.state
	fi
	journalctl -u agentd-apps@$APPS_UID -o cat --no-pager | tail -15
fi
GUEST
xorriso -as mkisofs -quiet -V cidata -J -r -o "$S/seed.iso" "$S/user-data" "$S/meta-data" "$S/guest.sh" "$S/agentd.deb" "$ROOT/tests/appsclient.py" \
	$([ -e "$S/gemini.env" ] && echo "$S/gemini.env") $([ -e "$S/blender" ] && echo "$S/blender")
qemu-img create -q -f qcow2 -b "$IMG" -F qcow2 "$S/disk.qcow2" 10G   # room for LibreOffice; the base image is never written
: >"$O/serial.log"
timeout -s KILL 2400 qemu-system-x86_64 -enable-kvm -cpu host -m 3072 -smp 4 -nographic -no-reboot \
	-drive file="$S/disk.qcow2",if=virtio -drive file="$S/seed.iso",if=virtio,media=cdrom,readonly=on \
	-nic user,model=virtio-net-pci -serial file:"$O/console.log" -serial file:"$O/serial.log" -monitor none -display none >/dev/null 2>&1 || true
tr -d '\r' <"$O/serial.log" | grep -vE "^\\s*$" | grep -v 'x-goog-api-key' || true
fail=0
for c in $EXPECT; do
	tr -d '\r' <"$O/serial.log" | grep -qx "CHECK $c ok" || { echo "missing or failed: $c" >&2; fail=1; }
done
exit $fail

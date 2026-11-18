#!/bin/bash
# Runs ON the Pi (as root, via debug-server.py send -). Real board, real units. Prints CHECK lines, timings and raw results.
H=/home/agentos; T0=$(date +%s.%N)
check() { if [ "$2" = 0 ]; then echo "CHECK $1 ok"; else echo "CHECK $1 FAIL"; fi; }
now() { date +%s.%N; }
el() { echo "$(echo "$(now) - $1" | bc) s"; }
client() { setpriv --reuid=nobody --regid=nogroup --groups="$(getent group agentd-apps | cut -d: -f3)" python3 -I /tmp/appsclient.py "$1"; }
which jq bc >/dev/null || { apt-get update -q >/dev/null 2>&1; apt-get install -y -q jq bc >/dev/null 2>&1; }
rm -f $H/t_*.* ; rm -rf $H/.agentd/undo/*
s=$(now); R=$(client '{"op":"run","cap":"libreoffice.create_text","args":{"output":"t_report.odt","title":"Quarterly report","body":"Sales rose 4 percent."}}'); echo "$R" | cut -c1-500; echo "TIME lo_create $(el $s)"
echo "$R" | jq -e '.status=="ok" and .output.state=="committed"' >/dev/null; check lo_create_committed $?
[ "$(stat -c %U $H/t_report.odt)" = agentos ]; check file_owned_by_person $?
s=$(now); R=$(client '{"op":"run","cap":"libreoffice.convert","args":{"input":"t_report.odt","format":"pdf","output":"t_report.pdf"}}'); echo "$R" | cut -c1-300; echo "TIME lo_convert $(el $s)"
[ "$(head -c 4 $H/t_report.pdf)" = "%PDF" ]; check lo_convert_pdf $?
echo "--- sandbox escapes"
client '{"op":"run","cap":"libreoffice.convert","args":{"input":"/etc/shadow","format":"pdf","output":"x.pdf"}}' | grep -q 'not a path inside the workspace'; check abs_path_refused $?
client '{"op":"run","cap":"libreoffice.convert","args":{"input":"../../etc/passwd","format":"pdf","output":"x.pdf"}}' | grep -q -i 'not a path\|refus\|escape\|invalid'; check dotdot_refused $?
ln -sf /etc/shadow $H/t_link.odt; client '{"op":"run","cap":"libreoffice.convert","args":{"input":"t_link.odt","format":"pdf","output":"x2.pdf"}}' | grep -q -i 'symlink\|not a\|refus'; check symlink_refused $?; rm -f $H/t_link.odt
echo "--- sandbox from inside (bwrap, same flags class)"
runuser -u agentos -- bwrap --unshare-all --die-with-parent --ro-bind /usr /usr --symlink usr/bin /bin --symlink usr/lib /lib --proc /proc --dev /dev --tmpfs /tmp sh -c 'curl -s -m 3 https://example.com >/dev/null 2>&1; echo net_rc=$?; ls /home 2>&1 | head -1; ls /etc/shadow 2>&1 | head -1' | tee /tmp/sbx.out
grep -q 'net_rc=[^0]' /tmp/sbx.out; check sandbox_no_network $?
echo "--- undo + state"
runuser -u agentos -- env HOME=$H AGENTD_WORKSPACE=$H agentd apps world 2>&1 | jq -c 'keys' | cut -c1-300
echo "--- blender"
NEW='{"op":"run","cap":"blender.new_scene","args":{"output":"t_scene.blend","code":"import bpy\nbpy.ops.mesh.primitive_cube_add(location=(0,0,1))\nbpy.ops.mesh.primitive_plane_add(size=20)\nbpy.ops.object.camera_add(location=(7,-7,5), rotation=(1.1,0,0.785))\nbpy.context.scene.camera=bpy.context.object"}}'
s=$(now); client "$NEW" | grep -q 'not approved'; check blender_script_needs_yes $?; echo "TIME approval_timeout $(el $s)"
[ ! -e $H/t_scene.blend ]; check no_file_without_yes $?
setpriv --reuid=nobody --regid=nogroup --groups="$(getent group agentd-users | cut -d: -f3)" python3 -I /tmp/appsclient.py --approver & AP=$!
s=$(now); R=$(client "$NEW"); echo "$R" | cut -c1-400; echo "TIME blender_new_scene $(el $s)"
echo "$R" | jq -e '.output.state=="committed"' >/dev/null; check blender_scene_created $?
s=$(now); R=$(client '{"op":"run","cap":"blender.add_light","args":{"file":"t_scene.blend","name":"Key","kind":"SUN","x":"4","y":"-4","z":"6","strength":"3"}}'); echo "$R" | cut -c1-400; echo "TIME blender_add_light $(el $s)"
echo "$R" | jq -e '.output.state=="committed"' >/dev/null; check blender_light_verified $?
runuser -u agentos -- env HOME=$H AGENTD_WORKSPACE=$H agentd apps state t_scene.blend > /tmp/bs.json 2>&1; head -c 500 /tmp/bs.json; echo
jq -e '.status=="verified" and (.structure.data.lights==["Key"])' /tmp/bs.json >/dev/null; check blender_state_structure $?
s=$(now); R=$(client '{"op":"run","cap":"blender.render","args":{"input":"t_scene.blend","output":"t_scene.png","percent":"10","samples":"4"}}'); echo "$R" | cut -c1-400; echo "TIME blender_render $(el $s)"
[ "$(head -c 4 $H/t_scene.png | tail -c 3)" = PNG ]; check blender_rendered $?
kill $AP 2>/dev/null
echo "TIME total $(el $T0)"

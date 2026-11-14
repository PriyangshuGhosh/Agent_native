#!/bin/sh
# Application layer against a real application (LibreOffice) on the host; no VM. Needs bwrap, soffice, python3-uno, jq.
# File route: create -> edit -> convert, each verified and committed. Live route: the same edit capability applied
# inside a running LibreOffice that has the document open (headless here; the UNO path is the one a window uses),
# verified by reading the open document back. Then: the human's unsaved and saved changes are seen, and a result
# is never written over a file that is open or that changed. Exit 0 = all checks passed.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
export PATH=$HOME/.cargo/bin:$PATH
CARGO_TARGET_DIR=$ROOT/build/agentd-host cargo build -q --locked --manifest-path "$ROOT/agentd/Cargo.toml"
T=$(mktemp -d /tmp/agentd-apps.XXXXXX)
W=$T/ws; mkdir -p "$W"
export AGENTD_WORKSPACE=$W AGENTD_CAPS=$ROOT/agentd/caps
A="$ROOT/build/agentd-host/debug/agentd apps"
fail=0; n=0
ok() { n=$((n+1)); if [ "$2" = "$3" ]; then echo "apps: ok   $1"; else echo "apps: FAIL $1 (got '$2', want '$3')" >&2; fail=1; fi; }
uno() { python3 -c "
import uno,sys
l=uno.getComponentContext()
c=l.ServiceManager.createInstanceWithContext('com.sun.star.bridge.UnoUrlResolver',l).resolve('uno:pipe,name=agentd-live;urp;StarOffice.ComponentContext')
d=c.ServiceManager.createInstanceWithContext('com.sun.star.frame.Desktop',c)
doc=[x for x in d.Components][0]
$1"; }
cleanup() { pkill -9 -f "soffice.bi[n].*$T/profile" 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT
if [ -S "/tmp/OSL_PIPE_$(id -u)_agentd-live" ] && uno "sys.exit(0)" 2>/dev/null; then
	echo "apps: a LibreOffice live session is already running; close it first" >&2; exit 1
fi

ok catalog_links_capabilities "$($A list | jq -r '[.[]|select(.id=="libreoffice-writer")|.capabilities|length>0]|any')" true
ok probe_gathers_evidence "$($A probe soffice | jq -r '(.help|length>500) and (.hints|index("has a headless mode")!=null)')" true

# --- file route
R=$($A run libreoffice.create_text output=report.odt title="Quarterly report" body="Sales rose 4 percent.")
ok create_committed "$(echo "$R" | jq -r '.state+" "+(.checks|length|tostring)')" "committed 3"
R=$($A run libreoffice.replace_text file=report.odt find="4 percent" replace="5 percent"); OP=$(echo "$R" | jq -r .op)
ok edit_committed "$(echo "$R" | jq -r .state)" committed
ok state_is_verified_with_structure "$($A state report.odt | jq -r '.status+"/"+.writer+"/"+(.structure.data.text|split("\n")|last)')" "verified/agent/Sales rose 5 percent."
ok convert_makes_pdf "$($A run libreoffice.convert input=report.odt format=pdf output=report.pdf | jq -r .state) $(head -c 4 "$W/report.pdf")" "committed %PDF"
ok bad_edit_fails_and_changes_nothing "$($A run libreoffice.replace_text file=report.odt find=absent replace=x 2>&1 | grep -c 'not found') $($A state report.odt | jq -r .structure.data.text | tail -1)" "1 Sales rose 5 percent."
$A undo "$OP" >/dev/null
ok undo_restores_previous_version "$($A state report.odt | jq -r .structure.data.text | tail -1)" "Sales rose 4 percent."

# --- live route: the document is open in a running LibreOffice
setsid soffice --headless --norestore --nologo "--accept=pipe,name=agentd-live;urp;" "-env:UserInstallation=file://$T/profile" "$W/report.odt" >/dev/null 2>&1 &
i=0; until uno "sys.exit(0)" 2>/dev/null; do i=$((i+1)); [ $i -lt 60 ] || { echo "apps: LibreOffice did not start" >&2; exit 1; }; sleep 0.5; done
H=$(sha256sum <"$W/report.odt")
R=$($A run libreoffice.replace_text file=report.odt find="4 percent" replace="9 percent")
ok live_edit_applied_in_open_document "$(echo "$R" | jq -r '.state+" "+(.unsaved|tostring)')" "applied_live true"
ok live_edit_left_disk_alone "$(sha256sum <"$W/report.odt")" "$H"
S=$($A state report.odt)
ok state_separates_disk_and_live "$(printf "%s" "$S" | jq -r '(.structure.data.text|test("4 percent")) and (.live.data.text|test("9 percent")) and .live.unsaved and .in_use and (.live.op!=null)')" true
uno "t=doc.Text; t.insertString(t.getEnd(), ' Human note.', False)"   # the human types in the window
ok human_unsaved_edit_is_seen "$($A state report.odt | jq -r '(.live.data.text|test("Human note")) and (.live.op==null)')" true
uno "doc.store()"                                                      # the human saves
ok human_save_detected_as_external "$($A sync | jq -r '[.[]|select(.path=="report.odt")|.change+"/"+.writer]|first')" "modified/external"
ok structure_refreshed_after_save "$($A state report.odt | jq -r '.status+"/"+.writer+" "+(.structure.data.text|test("9 percent.*Human note")|tostring)')" "observed/external true"
# a capability with no live route must not write over the open file: its result is kept beside it
printf 'x' >"$W/other.txt"
R=$($A run libreoffice.convert input=other.txt format=odt output=report.odt)
ok open_file_not_overwritten "$(echo "$R" | jq -r '.state+" "+.outputs[0].why')" "conflict the file is open in an application"
ok conflict_copy_kept "$(test -f "$W/$(echo "$R" | jq -r '.outputs[0].kept_as')" && echo yes)" yes
ok journal_records_routes "$($A ops | jq -r '[.[]|select(.route=="live")|.state]|first')" applied_live
echo "apps: $n checks, $( [ $fail = 0 ] && echo all passed || echo FAILED )"
exit $fail

#!/bin/sh
# Fast regression suite, no VM boot: agentd unit tests on the host, agent-init under -Werror, every gate's assertions
# against a recorded passing serial log (tests/fixtures/gate-0N-pass.log), and mutated logs each gate must reject.
# Gates 07/08 also need build/iso/{run1,run2,cua-agentos}.iso (scripts/build-iso-07.sh).
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
F=$ROOT/tests/fixtures
T=$ROOT/build/regress
mkdir -p "$T"
export PATH=$HOME/.cargo/bin:$PATH RUBRIC=$T/gate-08-rubric.jsonl  # keep the release run's rubric intact
fail=0
ok() { echo "regress: ok   $1"; }
bad() { echo "regress: FAIL $1" >&2; fail=1; }

CARGO_TARGET_DIR=$ROOT/build/agentd-host cargo test -q --locked --manifest-path "$ROOT/agentd/Cargo.toml" && ok agentd_unit || bad agentd_unit
gcc -static -Os -std=c99 -Wall -Wextra -Werror -o "$T/agent-init" "$ROOT/agent-init/agent-init.c" && ok agent_init_werror || bad agent_init_werror

for n in 01 02 03 04 05 06 07 08; do
	SERIAL_LOG=$F/gate-$n-pass.log "$ROOT/tests/gate-$n.sh" >/dev/null 2>&1 && ok "gate-$n accepts its pass log" || bad "gate-$n rejects its pass log"
done

# must_fail <name> <gate> <jq filter applied to each telemetry object of that gate's pass log> [extra JSON line]
must_fail() {
	jq -cR "fromjson? | objects | $3" "$F/gate-$2-pass.log" >"$T/$1.log"
	[ -z "${4:-}" ] || echo "$4" >>"$T/$1.log"
	if SERIAL_LOG=$T/$1.log "$ROOT/tests/gate-$2.sh" >/dev/null 2>&1; then bad "gate-$2 accepts $1"; else ok "gate-$2 rejects $1"; fi
}
must_fail pid1_late          02 'if .event=="PID1_READY" then .ts_ms=1001 else . end'
must_fail extra_process      02 'if .event=="PID1_READY" then .user_procs=2 else . end'
must_fail tier3_over_budget  04 'if .event=="TIER3_PASS" then .latency_ms=21 else . end'
must_fail no_workflow        05 'select(.event!="WORKFLOW_COMPLETE")'
must_fail dirty_rollback     06 'if .event=="ROLLBACK_VERIFIED" then .clean=false else . end'
must_fail failed_task        07 '.' '{"ts_ms":9999,"event":"TASK_COMPLETE","task_id":"t06-lifecycle","status":"fail"}'
must_fail self_set_budget    08 'if .event=="TIER2_PASS" then .latency_ms=60 | .budget_ms=100 else . end'
must_fail extra_process      08 'if .event=="PID1_READY" then .user_procs=2 else . end'
must_fail registry_mismatch  08 'if .event=="TASK_COMPLETE" and .task_id=="t06-lifecycle" then .registry=["test-cap","corrupt-cap"] else . end'
exit $fail

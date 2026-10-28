#!/bin/sh
# Build Cycle 05 into build/rootfs-05/: the Cycle 04 image plus the recorded Gemini plan agentd replays.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
ROOTFS_OUT=$ROOT/build/rootfs-05 PLAN_FIXTURE=$ROOT/tests/fixtures/gemini_plan.json exec "$ROOT/scripts/build-rootfs-04.sh"

# CUA-AgentOS

A minimal Linux distro that boots straight into a custom PID 1 (`agent-init`). That PID 1 starts an
autonomous agent runtime (`agentd`), and the agent is the primary user interface. The full spec is
in `overview/*.html`. If this file and the spec disagree, this file wins.

## Fixed decisions
- `agent-init`: POSIX C. It has no LLM code, no network calls and no inference. It is deterministic.
- `agentd`: Rust. No neural weights run locally.
- LLM: Google Gemini, with the key in env `GEMINI_API_KEY`. Never commit the key, never bake it into the
  rootfs/ISO, and never print it in logs. `*.env` is gitignored.
- Boot budgets: kernel start → `PID1_READY` ≤1000 ms. `PID1_READY` → `AGENTD_READY` ≤3000 ms.
- Dev host: Ubuntu 24.04.5 LTS, 8 GB RAM, KVM, sudo. The guest VM gets ≤4 GB RAM.
- Bare-metal validation is out of scope. The user does it manually, and no gate depends on it.

## Architecture (bottom → top)
Kernel (DRM/KMS, uinput, OverlayFS, VirtIO, SquashFS) → `agent-init` (VFS mounts, SIGCHLD reaping,
supervised restart) → D-Bus + AT-SPI bus → `cage` on headless output `HEADLESS-1` → `agentd`
(dispatcher, bounds validator, pre-/post-action verifier) ↔ Gemini (planning, JSON-RPC directives).

Tiers, from most preferred to least:
1. In-memory: `dlopen`/`dlsym` FFI and Wasm components. Target latency ≤1 ms.
2. Headless sockets: CDP WebSocket, Unix sockets, stdio. Target latency ≤50 ms.
3. Off-screen Wayland: AT-SPI `DoAction`/`SetTextContents`, with screencopy (≥10 FPS) and uinput as fallbacks.
   AT-SPI queries ≤20 ms.

Storage: a read-only SquashFS base, plus an OverlayFS with persistent `/data` and tmpfs scratch.

Guardrails in agentd:
- Clamp coordinates to the active output.
- Each step gets 30 s, then SIGKILL.
- Self-repair is capped at 3 iterations.
- SIGUSR1 is an emergency stop: unhook uinput immediately.

## Serial telemetry (the only gate evidence)
Output is JSON lines on `ttyS0`, one object per line: `{"ts_ms":<CLOCK_BOOTTIME ms>,"event":"<MARKER>",...}`.
Markers are fixed strings. Do not invent synonyms.
`PID1_READY`, `DBUS_READY`, `COMPOSITOR_READY`, `AGENTD_READY`, `INTERACTION_CYCLE_VERIFIED`,
`TIER1_PASS`, `TIER2_PASS`, `TIER3_PASS`, `WORKFLOW_COMPLETE`, `CAPABILITY_INSTALLED`,
`CAPABILITY_ROLLBACK`, `RUBRIC_PASS`, `RUBRIC_FAIL`.

## The 8 cycles (canonical; `overview/phases.html` is informational only)
| # | Cycle | Gate script (must exit 0) | Gate condition |
|---|-------|---------------------------|----------------|
| 01 | Primitives: headless Wayland, AT-SPI→JSON, uinput, screencopy ≥10 FPS | `tests/gate-01.sh` | Target UI actions are completed headlessly |
| 02 | Boot core: agent-init.c, mounts, reaping, kernel defconfig, QEMU boot | `tests/gate-02.sh` | `PID1_READY` ≤1000 ms; PID 1 = `agent-init`; no systemd/DM |
| 03 | Integration: D-Bus + compositor in rootfs, launched by PID 1, AT-SPI test under custom init | `tests/gate-03.sh` | `PID1_READY` ≤1000 ms; `COMPOSITOR_READY`; `INTERACTION_CYCLE_VERIFIED` ×4 (screencopy ≥10 FPS); QEMU exits 0 (`AGENTD_READY` deferred to the agentd cycle) |
| 04 | Routing: Tier 1/2/3 runners, capability selector | `tests/gate-04.sh` | `TIER1_PASS`, `TIER2_PASS`, `TIER3_PASS`, each within its latency budget |
| 05 | Cognition: intent parser, pre/post verification, replanning watchdog | `tests/gate-05.sh` | `WORKFLOW_COMPLETE` for a multi-step task |
| 06 | Storage: SquashFS base, OverlayFS upperdir, registry, atomic rollback | `tests/gate-06.sh` | install → run → verify passes, and an injected bad install emits `CAPABILITY_ROLLBACK` |
| 07 | Packaging: kernel + initramfs, GRUB, ISO script, QEMU boot | `tests/gate-07.sh` | ISO boots to agent prompt unattended; two builds have the same sha256 |
| 08 | Evaluation: rubric matrix, robustness faults, perf data, freeze | `tests/gate-08.sh` | Every rubric item passes (`RUBRIC_PASS` only) |

Every gate script:
- Runs non-interactively.
- Has a 300 s timeout (`timeout -s KILL 300`).
- Asserts only on serial JSON or on exit codes. It never asserts on human-read output.
- Assumes build artifacts already exist. Builds are run separately and do not count toward the 300 s.

## Working rules
- **One cycle per session.** Do not start the next cycle in the same session.
- **A cycle is done only when its gate script exits 0.** "Mostly works" counts as not done.
- When the gate passes, commit and tag it: `git tag cycle-0N`.
- Repair budget: 3 attempts per cycle. After that, stop, write up the blocker in `docs/`, and propose a fallback.
- Gates must be deterministic. Live Gemini output is not, so gates replay recorded responses (see Decisions).
- Repo layout: `agent-init/` `agentd/` `kernel/` `rootfs/` `iso/` `scripts/` `tests/` `docs/` `overview/` (spec).

## Decisions (resolved open questions, 2026-10-28)
All proposed defaults were accepted, with these pins:
- **Item 1 — Cycle 01 harness:** Cycle 01 runs inside a disposable minimal QEMU guest with KVM
  (`-snapshot`, no NIC), so uinput events never reach the host desktop.
- **Item 2 — compositor runtime:** compositor runs with headless display backend (`WLR_BACKENDS=headless`)
  with device input enabled as root, without a login manager. In practice this is
  `WLR_BACKENDS=headless,libinput` + `LIBSEAT_BACKEND=noop`, because uinput events reach cage only through libinput.
- **Items 3/4/5 — compositor, rootfs, test app:** `cage` is the kiosk compositor. It runs one app
  maximized, so the window origin is always (0,0) and no Wayland coordinate offset is needed.
  The rootfs is built from Alpine Linux packages. The Tier 3 test app is `mousepad` (GTK3).
- **Item 6 — model:** pinned to `gemini-2.5-flash`. Gate scripts use recorded/mocked responses only.
  Live API calls are a separate, non-gated validation test.

## Cycle status
| # | Status | Notes |
|---|--------|-------|
| 01 | **PASSED** (tag `cycle-01`) | Build: `scripts/build-harness.sh` (no root; Alpine v3.24 via `apk.static --usermode` + fakeroot). Gate: `tests/gate-01.sh` boots `build/harness/` under KVM in about 3 s. Probe: `rootfs/harness/run-primitives.py`. It measured screencopy at ~62 FPS. Repairs used: 3/3 (missing baselayout, missing SVG pixbuf loader, AT-SPI `get_text` shadowing). |
| 02 | **PASSED** (tag `cycle-02`) | Build: `scripts/build-initramfs-02.sh` (static glibc `agent-init`, Alpine `linux-virt` kernel, cpio holding only `/usr/bin/agent-init`, `rdinit=`). Gate: `tests/gate-02.sh` gives `PID1_READY` at ~270–290 ms. Mounts are read back from `/proc/self/mounts`, the fork/reap self-test passes with 0 zombies, PID 1 is the only user process, and QEMU exits 0 via `RB_POWER_OFF`. Repairs used: 1/3 (SeaBIOS left an unterminated serial line). Deferred: our own kernel defconfig; Alpine's virt kernel is used for now. |
| 03 | **PASSED** (tag `cycle-03`) | Build: `scripts/build-rootfs-03.sh` (static `agent-init` + Cycle 01 Alpine rootfs via `build-harness.sh` knobs; initramfs switch_roots to `/usr/bin/agent-init`). agent-init runs the oneshot `/etc/agent-init/prep` (uinput, udevd, caches), then supervises dbus-daemon (`/run/user/0/bus`), at-spi-bus-launcher and `cage -- mousepad` (restart ≤3), runs `run-primitives.py` as the final step, and powers off when it exits (SIGTERM all → 2 s → SIGKILL → sync → `RB_POWER_OFF`). Gate: `tests/gate-03.sh` gives `PID1_READY` at ~370 ms, all 4 primitives pass, screencopy ~61 FPS, about 4 s total. Repairs used: 0/3. Per the user's choice, `AGENTD_READY` is **not** gated here; it moves to the first cycle that builds Rust `agentd` (no Rust toolchain on the host yet). |
| 04 | next | Routing: Tier 1/2/3 runners. Start it in a new session. |

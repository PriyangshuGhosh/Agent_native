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
`CAPABILITY_ROLLBACK`, `CAPABILITY_VERIFIED`, `RUBRIC_PASS`, `RUBRIC_FAIL`.
Cycle 05 cognitive-loop markers (added at the user's request): `TASK_START`, `STEP_VERIFIED`,
`REPLAN_TRIGGERED`, `TASK_COMPLETE`. `WORKFLOW_COMPLETE` stays the canonical gate marker.
Cycle 06 storage/lifecycle markers (added at the user's request): `STORAGE_READY`, `LIFECYCLE_INSTALL`,
`LIFECYCLE_VERIFIED`, `LIFECYCLE_FAIL_INJECTED`, `ROLLBACK_TRIGGERED`, `ROLLBACK_VERIFIED`. They are emitted
alongside the canonical `CAPABILITY_INSTALLED` / `CAPABILITY_ROLLBACK`, and gate 06 asserts both sets.

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
| 04 | **PASSED** (tag `cycle-04`) | Build: `scripts/build-rootfs-04.sh` (rustup toolchain in `~/.cargo`; agentd is Rust, `--target x86_64-unknown-linux-musl --release`, but it is linked **dynamically** against Alpine's musl and libgcc_s, fetched into `build/musl-sysroot`, because a fully static musl binary cannot `dlopen`). agent-init's FINAL is now `/usr/bin/agentd` (`-DFINAL_CMD` keeps Cycle 03 on the probe). agentd waits for the bus and wayland-0, emits `AGENTD_READY`, then runs Tier 1 (dlopen `libtier1.so` copied to tmpfs, about 0.07 ms), Tier 2 (`tr` over stdio pipes, about 6 ms) and Tier 3 (zbus 5 → AT-SPI `SetTextContents`/`GetText` on mousepad, about 4 ms). Each tier emits `CAPABILITY_VERIFIED` plus `TIERn_PASS` when it is within budget. Gate: `AGENTD_READY` at about 1.7 s after `PID1_READY`, about 3.4 s total. Repairs used: 0/3. Not done yet: capability selector, 30 s step SIGKILL, SIGUSR1 stop. |
| 05 | **PASSED** (tag `cycle-05`) | Build: `scripts/build-rootfs-05.sh` (wraps the 04 builder via `ROOTFS_OUT`/`PLAN_FIXTURE`; bundles `tests/fixtures/gemini_plan.json` at `/usr/share/agentd/`). After the tier proofs, agentd replays recorded `gemini-2.5-flash` generateContent responses: [0] = plan, one more per replan. Directive schema parser (tier/action pairing enforced, `$N` = step N output), pre-validator (AT-SPI role + `GetState` bits, `path_exists`), dispatch Tier 3 `set_text` → Tier 2 `pipe` (tr) → Tier 1 `ffi_call` (allow-listed `tier1_fnv1a`), post-verifier (`expected_postcondition.output`), and a replan watchdog with a budget of 3. The fixture deliberately predicts role `entry` for step 1, which gives one `REPLAN_TRIGGERED` and then recovery. Gate: `tests/gate-05.sh` gives `PID1_READY` at ~380 ms, `AGENTD_READY` ~1.7 s later, `WORKFLOW_COMPLETE` with 1 repair, about 3.4 s total. Gate 04 still passes on this image. Repairs used: 0/3. Not done yet: 30 s step SIGKILL, SIGUSR1 stop, live Gemini client. |
| 06 | **PASSED** (tag `cycle-06`) | Build: `scripts/build-rootfs-06.sh` (wraps 05 with `BASE_FS=squashfs`/`PACKAGES_DIR`). The rootfs is a zstd SquashFS (`-all-root`) attached as a read-only raw virtio disk. The initramfs loads squashfs and overlay, mounts the base ro, puts upper/work on tmpfs, mounts the overlay root, and moves both layers to `/mnt/base` and `/mnt/rw`. agent-init emits `STORAGE_READY` (base listed `ro` **and** a write gives EROFS; root is overlay; upper is tmpfs). agentd installs each package in `/usr/share/agentd/packages/queue` (tar → `/tmp` stage → `/usr/local/bin`|`/opt` only) as a journaled transaction that also covers `/data/registry.json`. It runs the manifest's verify argv (30 s SIGKILL cap) and rolls back on failure, then checks that prior bytes and mode are restored, there is no upper/whiteout residue, nothing is in the base, and the registry entry is gone. `corrupt-cap` (non-executable payload) gives ENOEXEC → rollback, clean. Gate: `PID1_READY` ~340 ms, `AGENTD_READY` ~1.9 s later, about 3.6 s total. Gates 02–05 still pass. Repairs used: 0/3. Not done yet: persistent `/data` (upper is tmpfs, so the registry does not survive a reboot), network acquisition (packages ship in the base), SIGUSR1 stop. |
| 07 | **PASSED** (tag `cycle-07`) | Build: `scripts/build-iso-07.sh` (`SOURCE_DATE_EPOCH=1700000000`). It builds the Cycle 06 system from scratch twice with `BASE_FS=iso` into `build/iso/run{1,2}.iso` and copies run1 to `cua-agentos.iso` (~189 MB). ISOLINUX comes from Alpine's `syslinux` apk. The ISO holds `/boot/{vmlinuz,initramfs}` and `/rootfs.squashfs`. The initramfs loads sr_mod/isofs/loop, mounts `/dev/sr0`, loop-mounts the SquashFS as the base, and moves the CD to `/mnt/cd`. Reproducibility: sorted cpio with `--reproducible`, epoch mtimes and `gzip -n`; `mksquashfs -reproducible -no-xattrs -mkfs-time/-all-time`; `var/log/apk.log` is dropped; `xorriso -r` with epoch-touched files. Gate: `tests/gate-07.sh` checks run1 == run2 == the booted ISO (sha256) and boots with `-cdrom` only (no `-kernel`/`-initrd`). `PID1_READY` ~400 ms, `AGENTD_READY` ~1.5 s later, `TASK_COMPLETE`, about 5 s total. Gates 02–06 still pass. Repairs used: 1/3 (initramfs placeholder never substituted; apk.log timestamps). `agent.test_poweroff` is **not** on the ISO boot line because agent-init treats it as "power off before services" (gate 02); agentd exiting powers off. Not done yet: an interactive agent prompt (the unattended run powers off), UEFI boot, persistent `/data`, pinning Alpine package versions (a mirror update between the two builds would break the match). |
| 08 | **PASSED** (tag `cycle-08`) | Build: `scripts/build-iso-07.sh`, then `scripts/release-08.sh`, which copies the ISO to `release/`, writes `release/SHA256SUMS` (vmlinuz, initramfs, rootfs.squashfs, ISO), runs gate 08 against `release/cua-agentos.iso` and writes `docs/grading-report.md` (also in `release/`) from that run's serial log. The ISO boot line now has `rdinit=/usr/bin/agent-init`: the kernel execs agent-init from the initramfs, it execs `/stage1` (busybox mount script; `/init` is kept because busybox `switch_root` requires it), and that switch_roots back to agent-init on the overlay root, still PID 1. `PID1_READY` carries `cmdline`. agentd adds a Tier 3 screencopy probe (15 grim frames of `HEADLESS-1` → `INTERACTION_CYCLE_VERIFIED` `fps`, about 60). Gate: `tests/gate-08.sh` prints one `RUBRIC_PASS`/`RUBRIC_FAIL` line per category (kernel_handoff 20, bare_metal_pid1 20, perception_3tier 25, app_lifecycle 25, immutable_artifact 10) to stdout and `build/gate-08-rubric.jsonl`, and needs 100/100. `PID1_READY` ~390 ms, `AGENTD_READY` ~1.6 s later, about 3 s total. Gates 02–07 still pass. Repairs used: 1/3 (busybox `switch_root` needs `/init`). The ISO (~189 MB) is gitignored and not committed; its sha256 is in `release/SHA256SUMS`. |

**Final build status (2026-10-28):** all 8 cycles PASSED. Release: `release/cua-agentos.iso`
(sha256 `b26f2fdd3ea1ea6dfebc058635f9c17c9369caf99a78b2b994d8c5aa4ad9431f`, reproducible from `scripts/build-iso-07.sh`),
rubric 100/100 (`docs/grading-report.md`).

**Hardening pass (2026-10-29):** see `docs/hardening-2026-10-29.md`. Now done: the 30 s step SIGKILL (process-group kill),
the SIGUSR1 emergency stop, strict directive validation and allow-lists, a crash-safe install journal, and persistent `/data`
(ext4 disk labelled `agentos-data`, optional; it is exercised by `tests/test-persist.sh`). Fast suite: `tests/regress.sh`.
All gates were rerun from a clean rebuild.

**Raspberry Pi 5 image (2026-10-29, not gated):** `scripts/build-pi5-img.sh` cross-builds the Cycle 06 system for aarch64
(`ARCH=aarch64 KERNEL=rpi CROSS=aarch64-linux-gnu- BASE_FS=mmc`) into `build/pi5/cua-agentos-pi5.img`: MBR, p1 FAT32 boot
(config.txt, cmdline.txt, Alpine `linux-rpi` kernel, initramfs, bcm2712 DTBs), p2 raw SquashFS (`/dev/mmcblk0p2`).
Needs `gcc-aarch64-linux-gnu qemu-user-static mtools` (rootless copies: `. build/cross/env.sh`). Telemetry goes to
`AGENT_TTY` (kernel cmdline env, default `/dev/ttyS0`; the Pi writes `agentos.log` on its FAT partition, no serial cable).
The image ran on a real Pi 5 (all checks pass except AGENTD_READY 4.1 s > 3 s). Progress and next steps: `docs/pi5-2026-10-29.md`.

## Debian base direction (2026-10-29, branch `debian-base`)
Product direction is now `CUA-AgentOS_goal.md`: a general-purpose distro (amd64 + arm64, Pi 5 first among the ARM boards),
built as **Debian 13 (trixie) + our packages**. The work is reused, not reinvented. The Alpine/agent-init cycles above
stay as a record, and their gates must keep passing. On Debian: systemd is PID 1, and agent-init and the ≤1000 ms boot
budgets do not apply. amd64 is tested only in a throwaway KVM guest (`-snapshot`); hardware tests happen on the Pi 5.
- **Model:** `gemini-2.5-flash` is closed to new API keys, so live calls use `AGENTD_MODEL` (default
  `gemini-3.6-flash,gemini-3-flash-preview,gemini-3.8-flash`, tried in order; 3.8 timed out on every call when measured),
  with Gemini `responseSchema` forcing the directive shape. The Alpine gates still replay the recorded 2.5-flash fixture.
- **Step 1 (done):** `scripts/build-deb.sh` builds `build/deb/agentd_<ver>_amd64.deb`: `agentd serve` as `agentd.service`
  (DynamicUser, ProtectSystem=strict, Restart=on-failure with StartLimitBurst=5/60 s). Requests arrive through
  `agentd.socket` (`/run/agentd.sock`, 0660, group `agentd-users`, socket-activated, so it survives agentd restarts);
  `agentd ask <request>` is the root/admin client. The key goes in `/etc/agentd/gemini.env`
  (`GEMINI_API_KEY=...`, optional; without it, tasks fail with "planner unavailable" and the service stays up). It reaches
  curl only through its stdin config. Planner actions on Debian: Tier 2 `tr` only (`/run` is noexec, so Tier 1 cannot
  dlopen there, and there is no GUI for Tier 3). Test: `scripts/fetch-debian-cloud.sh`, then `tests/test-debian-vm.sh`
  (11 checks, including a live Gemini plan → execute → verify; about 1 min).
- **Step 2 (done):** `agentd-console.service` runs `agentd console` on tty1 (it takes tty1 from getty; tty2 keeps a
  normal login as the recovery route). It is an unprivileged client in group `agentd-users`. It prints each task in
  plain words (plan, each verified step, repairs, outcome, and "Nothing was changed" when no plan ran). `status` and
  `help` are answered locally, without the model: the console sends `/status` and agentd replies with the event
  `AGENTD_STATUS` (planner, models, uptime, tasks), which was added for this step. No approval prompts yet, since there
  are no high-risk actions. Tested by piping input through the console in the VM; tty1 has not yet been looked at on a
  real screen.
- **Next:** step 3, an mkosi config that builds both the amd64 image and the Pi 5 SD image (arm64 .deb).

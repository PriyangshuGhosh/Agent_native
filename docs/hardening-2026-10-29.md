# Hardening pass (2026-10-28/29)

A fix pass over cycles 01–08: no new cycle, and the architecture is unchanged. Every gate was rerun from a clean rebuild on the
final code (see "Verified").

## Fixes

### agentd (`agentd/src/main.rs`)
- **Child processes** (`run_capped`): each child runs in its own process group with `PATH` as its only environment variable.
  The whole group is SIGKILLed at the 30 s step cap, on emergency stop, and as soon as the leader exits, so a backgrounded
  grandchild cannot outlive its step. `waitid(WNOWAIT)` keeps the group id from being reused before the kill. stdin and
  stdout are pumped on threads, which removes a pipe deadlock on large input, and stdout is capped at 1 MiB.
- **Emergency stop**: on SIGUSR1, agentd kills the running child's group and refuses every further UI action, FFI call and
  child process. A stopped task is never replanned around.
- **Directive validation**: the schema is strict. The tier and action must pair up. Tier 2 executables must be exact
  allow-listed paths, so `/usr/bin/../bin/tr` is rejected. The Tier 1 library must be the exact path and the symbol must be on
  the allow-list. Every arg must be a string, and there are at most 16. `$N` may only refer to an earlier step. Duplicate
  steps, a mismatched `task_id`, an unknown precondition or AT-SPI state, a non-string role and a missing postcondition are
  all rejected. The Tier 2 and Tier 1 allow-lists are checked again at dispatch time.
- **Transactional install**: there is now an on-disk write-ahead journal (`/data/.agentd-txn`), and a transaction cut short
  by a crash is rolled back at the next start. Writes are atomic: an `O_EXCL` temp file, fsync, rename, then fsync of the
  directory. Rollback restores the prior bytes **and** mode. A package's sources must be regular files inside the package, so
  `..` and symlinks out of it are refused. Destinations are limited to `/usr/local/bin` and `/opt` and may never shadow a
  file in the base. `verify.argv[0]` must be a file that this package installed. A corrupt or non-object registry is an error
  and is never silently overwritten. The rollback check also handles upgrades correctly: the old registry entry is kept.
- **Screencopy regression (found this pass)**: once the environment was cleared, `grim` lost the Wayland socket and
  screencopy failed on every image. Now only agentd's own screencopy call gets `WAYLAND_DISPLAY`/`XDG_RUNTIME_DIR`.

### agent-init (`agent-init/agent-init.c`)
- A SIGTERM or SIGINT that arrives during service start-up is acted on at once, instead of after the ready waits.
- If the FINAL workload cannot be forked, agent-init shuts down instead of hanging forever.
- **Clean power-off (found this pass)**: agent-init now remounts `/` and `/mnt/rw` read-only after `sync`. Before, every boot
  left the persistent ext4 disk needing journal replay.
- **Per-boot app state (found this pass)**: the session's `XDG_{CONFIG,DATA,CACHE,STATE}_HOME` now live on tmpfs. Before,
  mousepad restored the previous boot's session from the persistent disk and Tier 3 could not find its editor.
- `STORAGE_READY` reports `persistent` and accepts an ext4 upper.

### Storage, build scripts and gates
- **Persistent `/data`**: when an ext4 disk labelled `agentos-data` is attached, the initramfs uses it as the overlay upper;
  otherwise the upper is tmpfs, as before. The registry and installed capabilities survive a reboot.
- The host-run `apk-tools-static` and `syslinux` downloads are pinned by sha256.
- **Stalled downloads (found this pass)**: apk's `--timeout` misses a download that stalls mid-transfer, which hung the build
  twice on `linux-virt`. Each apk run now has a 600 s wall-clock cap, and `apk add` is retried up to 3 times.
- Gate 07 fails if any task reports a status other than success.
- Gate 08 scores tiers against fixed budgets (1, 50 and 20 ms), not the `budget_ms` agentd reports for itself, and requires
  `user_procs == 1`.

## Regression tests
- `cargo test` (5 tests): schema and policy rejections (17 cases), rollback plus destination confinement, crash recovery,
  registry and package-source validation, the step cap, group kill, minimal env, the screencopy env, and SIGUSR1 stop.
- `tests/regress.sh`: unit tests, agent-init under `-Werror`, each gate run against its recorded pass log
  (`tests/fixtures/gate-0N-pass.log`), and 9 mutated logs that the gates must reject.
- `tests/test-persist.sh` boots Cycle 06 three times with one data disk. It checks that the disk persists, that every
  power-off leaves it clean, that each boot gets a fresh editor, and that a planted half-finished transaction is rolled back
  at start.

## Verified (2026-10-29)
Clean rebuild of every cycle, then: gates 01–08 exit 0, `tests/test-persist.sh` exits 0, and `tests/regress.sh` passes 19/19.
`run1.iso` == `run2.iso` == the booted ISO, sha256 `b26f2fdd3ea1ea6dfebc058635f9c17c9369caf99a78b2b994d8c5aa4ad9431f`.
`scripts/release-08.sh`: rubric 100/100.

## Limitations (not done or not proven)
- SIGUSR1 stop and the 30 s cap are proven by host unit tests only; no gate sends SIGUSR1 inside the VM. agentd opens no
  uinput device, so "unhook uinput" has nothing to act on today.
- A child that calls `setsid` leaves the process group and is not killed. agentd only detects it, because the child is
  still holding stdout. In-process Tier 1 FFI calls cannot be time-capped.
- `alpine-keys` is trusted over HTTPS alone, and Alpine package versions are not pinned, so the ISO reproduces only while the
  mirror stays the same between builds.
- Still open: a live Gemini client (gates replay recorded responses), the capability selector, an interactive prompt, UEFI
  boot, bare-metal validation (out of scope) and network acquisition of capabilities.

## Reproduce
```sh
export PATH=$HOME/.cargo/bin:$PATH
scripts/build-harness.sh && tests/gate-01.sh
scripts/build-initramfs-02.sh && tests/gate-02.sh
scripts/build-rootfs-03.sh && tests/gate-03.sh
scripts/build-rootfs-04.sh && tests/gate-04.sh
scripts/build-rootfs-05.sh && tests/gate-05.sh
scripts/build-rootfs-06.sh && tests/gate-06.sh && tests/test-persist.sh
scripts/build-iso-07.sh && tests/gate-07.sh && tests/gate-08.sh
scripts/release-08.sh   # release/ + docs/grading-report.md
tests/regress.sh        # fast suite, no VM
```

# PROJECT_STATE

Handoff file. Any model/engineer resuming: read this, then `docs/RESUME.md` (host setup, commands, Pi notes) and
`CLAUDE.md` (history, fixed decisions). Mandate: the user's "Agent_native autonomous engineering mandate"
(2026-11-14): a general-purpose agent-native OS where the OS understands and operates ordinary applications.
Keep replies short; update this file after each milestone.

## Assessment (2026-11-14, verified by reading code, not reports)
- Real and reusable: Debian 13 image build (amd64 + Pi 5 arm64), `agentd` (Rust; planner loop, strict directive
  validation, replan budget, 30 s kill, SIGUSR1 stop), root broker with compiled-in policy + approvals + audit,
  journalled transactions (`agentd/src/txn.rs`), console on tty1, debug link, VM tests.
- Record only: Alpine/agent-init cycles 01-08 (gates must keep passing; not the product).
- Inadequate for the mandate: the agent could only run `tr`, five read tools, 3 service ops, `set_ntp`.
  No application discovery, no capability knowledge, no app state model, no human/AI coordination, no extensibility.
- `build/` holds only the Pi image, cross tools, debug keys. `.deb` and cloud image must be rebuilt/fetched before VM tests.

## Architecture decisions (mine; challenge with evidence)
1. Keep Debian + systemd + agentd + broker. Add an **application layer** in `agentd/src/apps.rs`.
2. **Capabilities are data, not code**: JSON manifests (`app`, `id`, `binary`, typed `params`, `argv` template,
   embedded `files`, `verify` checks, `kind` action|inspect, `handles` extensions). Built-in ones ship in
   `/usr/share/agentd/caps/` (root-owned); generated ones live in `<workspace>/.agentd/caps/` and need human
   approval. New app = new manifests, no core change.
3. **Every app operation runs in bubblewrap**: no network, read-only system, inputs bound read-only at `/in/N/`,
   outputs staged in `/out`, manifest files at `/cap`. Never runs unsandboxed; no shell, argv only.
4. **Verify the staged result, then commit by compare-and-swap**: `renameat2(RENAME_NOREPLACE)` for new files,
   `RENAME_EXCHANGE` for replacements, then the displaced file is hashed; if it is not the version the agent
   started from (a human edited it), swap back and keep the agent's result as `<name>.agent-<op>.<ext>` (conflict).
   Displaced versions go to `.agentd/undo/<op>/` (undo). A file in use by a human app (lock file, open fd,
   cmdline) is never replaced.
5. **World state** `.agentd/world.json`: per file: hash, size, mtime, status (`observed` | `verified` | `expected`
   | `inferred` | `gone`), last writer (`agent` | `external`), app-level `structure` from an inspector
   capability with its own status (`verified`/`observed`/`outdated`). `sync` reconciles with disk (metadata first,
   hash only on change). `changes.jsonl` records external changes for the planner.
6. **Ops journal** `.agentd/ops.jsonl` (`running` → `committing` → final). Recovery on start resolves any
   interrupted op from the hashes recorded before the swap; nothing is lost in any crash window.
7. **Investigation**: evidence = sandboxed `--help`/`--version`, man page, .desktop data, dpkg description. Treated
   as untrusted text. The model proposes manifests + a self-test; the system validates, runs the self-test in
   the sandbox, and stores only what passes. Binary must be the investigated app's own.
8. **Privilege split**: agentd (planner, network, no user files) → app runner (the human user's uid, no network,
   sandbox per op) → broker (root, typed ops). Approvals never route through agentd.
10. **Live sessions (user requirement, 2026-11-14: the AI must act inside the app window that is open on screen)**:
   a manifest may define a `session`: how the OS launches the app with a control bridge (LibreOffice UNO pipe,
   Blender `bpy` timer server on a Unix socket, GTK `org.gtk.Actions` on D-Bus, AT-SPI fallback) and live
   capabilities that call it. If the target document is open in a live session, operations go through the bridge
   (the human sees them; unsaved state is read through the bridge); otherwise the sandboxed file route is used.
   Needs a real desktop compositor in the image (labwc), not the cage kiosk.
9. Hash: `sha2` crate (pure Rust; musl-safe so the Alpine gates still build). State is JSON files, not SQLite
   (shortcut: fine to thousands of files; move to SQLite if the workspace is larger).

## Progress
- [x] Repo + environment assessment
- [x] M1 `agentd/src/apps.rs` core: catalog (`scan_apps`), manifests (`check_manifest`, `load_caps`, packs with shared
      `files`/`@file`), bwrap `sandbox`, `run` (verify -> CAS commit), world state + `sync`, `state` (inspector on
      demand), `undo`, `recover`, `probe` (evidence), CLI `agentd apps list|caps|probe|run|state|open|world|sync|changes|ops|undo|recover`
- [x] M1b live sessions: generic `session` {socket, binary, list, inspect, launch, handles} + per-capability `live.argv`;
      `run` routes to the open application when the file is open there; result verified by reading the open document;
      world entry gets `live` (unsaved flag, data, which op). LibreOffice pack: `agentd/caps/libreoffice.json` + `_lo.py` (UNO) + `_odf.py`.
- [x] M2 planner path: Tier 2 action `app` (target = capability, args `name=value`, `$N`, `@stdin`); `agentd apprunner`
      (sockets `/run/agentd-apps.sock` group agentd-apps, `/run/agentd-apps-approve.sock` group agentd-users);
      approvals go console -> runner, never through agentd; planner prompt gets `apps::context` (capabilities, files, changes);
      console prints app results in plain words. Units in `agentd/debian/agentd-apps*.{service,socket}`; `.deb` builds.
- [x] M2b decided against an inotify watcher for now: every request starts with `sync` (metadata compare, hash on
      change), which is what correctness rests on; a watcher would only make staleness visible between requests and
      needs locking on world.json. `stale` status and `mark_stale` removed. Revisit if the console should announce changes live.
- [x] M3 `learn` (code + unit test; live-model run not yet evidenced): planner action `learn` (target = program) ->
      runner `probe` -> model writes manifests from the evidence (`LEARN_PROMPT` in main.rs) -> runner `install`:
      structural check, binary must be the examined one, no replacing, self-test run in the sandbox in a scratch
      workspace -> stored `generated` in `.agentd/caps/` -> planner is told and plans again. Limit: self-test inputs are text files only.
- [x] M3b Blender pack (`agentd/caps/blender*.{json,py}`): new_scene/script (bpy, approval), add_light, render, inspect, live bridge. VM-tested.
- [ ] More packs / mechanisms: ImageMagick/ffmpeg (try via `learn`), GTK apps via `org.gtk.Actions`
- [x] M4 VM test `tests/test-apps-vm.sh` passes 21/21.
- [x] M4b image booted on the real Pi 5 (2026-11-14, labwc + console): live Gemini tasks, `blender.new_scene` made
      `hat.blend` (verified; 17 s) through the planner. Evidence: `build/debug/pi.log`.
- [x] M4c desktop for the person (user request 2026-11-14: see the agent's work on the screen; files and apps by
      mouse). FlowOS was asked for as a source: it is closed source (its site says so; early access Dec 2026), so nothing
      could be taken. Done: waybar panel (`/etc/agentos/waybar.{jsonc,css}`: Agent/Files/Terminal/Writer/Blender
      buttons, taskbar, clock), pcmanfm; a document double-click runs `agentd apps open` (`agentos-open.desktop` +
      `/etc/xdg/mimeapps.list`) so the window has the control socket; the runner opens every committed output on the
      desktop (`apps::run` -> `open(.., wait)`, joins `/run/user/<uid>/wayland-0`, sets `DISPLAY=:0`, reaps the child;
      console says "opened it on the screen"), so later steps go live into that window. Xwayland is in the image.
      **Pi 5 facts (measured 2026-11-14):** Debian's arm64 Blender 4.3 has only the X11 back-end, and it needs OpenGL
      4.3 while the Pi 5 GPU (V3D 7.1) stops at 3.1 (`GLXBadFBConfig`; a GL override dies on "max 0 SSBO"), so Blender
      is launched with `LIBGL_ALWAYS_SOFTWARE=1` (panel button and `blender.json` session launch; ~8 s to a window).
      Evidence: `tests/test-debian-img.sh` 27/27 on amd64 (screenshots `build/evidence-2026-11-14/desktop-run{3,4}.png`:
      the agent's Writer document open on the desktop); on the real Pi 5 "create a hat in blender" -> `hat.blend`
      verified in 32 s and opened in Blender on screen (`"opened":["hat.blend"]`, bridge socket up); Writer documents
      the same. Not yet seen on the Pi: a second step going live into the open Blender window. Then: `learn` with the live model.
- [x] M4d growth (user request 2026-11-14, risk accepted by the user; they review afterwards): planner action Tier 2
      `shell` (target `/bin/sh`, command in stdin) -> runner op `shell` (`apps::shell`): runs as the person, in their
      home, not sandboxed, with network, 120 s cap, journalled in ops.jsonl. Broker op `pkg.install` (Debian package
      name, always asks on the console, `agentd-pkg@<name>.service` runs apt-get, dpkg record is the check; rate limit
      3 per 10 min). `AGENTD_TRUST_GENERATED=1` in agentd-apps.service: learned capabilities run without the first-use
      question; `agentd apps review` / `forget <cap>`. Evidence: unit 21+6; `tests/test-debian-img.sh` 30/30 (run 8;
      run 6 had one LibreOffice python segfault in create_text, run 7 the model answered the typed task differently:
      both passed on rerun, neither understood further). Not yet on the Pi.
- [ ] M5 GUI fallback for apps with no scriptable interface (AT-SPI code from the Alpine cycles)
- [ ] M6 Pi 5: boot the arm64 image, resource measurements, power-pull test (needs the user's hands)
- [ ] M7 local planner option (OpenAI-compatible endpoint; Hailo-10H compatibility must be measured, not assumed).
      Without any model the layer still works: `agentd apps run <cap> name=value` needs no network.
- [ ] Older open items from `docs/RESUME.md`: health checks (chunk 6), updates/persistence, pinned image builds
- [x] 2026-11-18: Pi 5 card read back: 34 app operations on hardware (26 committed, 2 conflicts kept the human's file,
      11 failed safely: approvals refused, model mistakes, all recovered or refused before running). `docs/pi5-results-2026-11-18.md`.
      Released as `v2.0.0` (Pi 5 image `release/pi5/cua-agentos-pi5.img.xz` on GitHub; checksums in `release/pi5/SHA256SUMS`).

## Known limits of what exists (be honest about these)
- Live route tested only against headless LibreOffice on the host (same UNO path a window uses); not yet seen on a screen.
- Human edits in a live session were simulated through UNO, not typed.
- `in_use` scans /proc per call; fine for single operations, slow if called for hundreds of files.
- A live session socket in /tmp is trusted by path (`/tmp/OSL_PIPE_<uid>_agentd-live`); another local user cannot
  create that name for our uid's LibreOffice, but this needs a review before multi-user use.
- The runner serves one request at a time.
- `sync` hashes every changed file up to 64 MiB; first run on a large home is slow.

## Known issues / obstacles
- Pi 5 not reachable from this host on 2026-11-14 (192.168.1.5 no ping): no hardware testing this session.
- Hailo-10H: nothing in the repo or host verifies any model on it. Unverified.
- Rotate the Gemini key if not done (it was printed once; see RESUME).

## Test evidence (label by level)
- Unit (host, `cargo test`, 2026-11-14): 20 pass (incl. learned-capability install: wrong binary / failing self-test / replacement refused). New: sandbox blocks network/home/workspace writes; path escapes and
  symlinks refused; verified commit; conflict never overwrites; undo; crash recovery on both sides of the swap;
  generated capability needs approval and cannot shadow a built-in; planner `app` action through the runner socket
  with console approval (no -> refused, yes -> runs).
- Integration (host, real LibreOffice 24.2, `tests/test-apps-host.sh`, 2026-11-14): 17/17. File route create/edit/
  convert/undo; live route edit in an open document (0.25 s), disk untouched, human unsaved edit seen, human save
  detected as external, open file not overwritten.
- VM (Debian 13 cloud image, KVM, `BLENDER=1 tests/test-apps-vm.sh`, 2026-11-14, run 6): **21/21, exit 0**
  (log: `build/evidence-2026-11-14/apps-vm-run6.log`). Under the real systemd units: runner is `agentos`, socket is
  group-only, sandboxed LibreOffice create/convert, ownership, world state, external change seen, outside path refused;
  live-Gemini-planned create+convert (2 steps, 0 repairs); live-planned edit applied inside a running LibreOffice, disk
  untouched; Blender: script refused without a yes, scene created by an approved bpy script, typed `add_light` verified
  by the scene inspector, Cycles render to PNG, `add_light` through the live bridge into a running Blender, and a
  live-planned "create a scene ... render it" (model-written bpy script, approved, verified, rendered; 2 steps, 0 repairs).
  Runs 1-5 failed and were fixed: AF_NETLINK missing in the unit; negative ints read as options; no OpenImageDenoise
  in Debian's Blender; a disconnected console counted as "no"; a refusal triggered replanning; the live route ran the
  app binary instead of the session client; **a repair that omitted the failed step let the task succeed without it**
  (pre-existing loop bug, now fixed with a regression test); my test wrongly required an *active* camera.
  The planned Blender task is model-dependent: it passed in runs 3 and 6, failed for real reasons in 2 and 4.
- VM regression (`tests/test-debian-vm.sh`, 2026-11-14, after all changes): 24/24 (`build/evidence-2026-11-14/debian-vm-run.log`).
- Unit: 20 pass (added: a repair cannot drop the failed step).
- Pi 5: not run.
- `tests/regress.sh` (2026-11-14): 17 ok; gate-07/08 replay FAIL only because `build/iso/*.iso` is absent (build/ was wiped 2026-11-08; run `scripts/build-iso-07.sh`).
- Not rerun this session: Alpine gates 01-08 in QEMU, `tests/test-debian-vm.sh` (agentd changed: rerun them).

## How to continue (commands)
```sh
tests/test-apps-host.sh                      # 17 checks, ~40 s, needs bwrap soffice python3-uno jq
cd agentd && CARGO_TARGET_DIR=../build/agentd-host cargo test --locked
scripts/build-deb.sh && scripts/fetch-debian-cloud.sh   # then the VM tests
AGENTD_WORKSPACE=$HOME/somefolder AGENTD_CAPS=$PWD/agentd/caps build/agentd-host/debug/agentd apps caps
```

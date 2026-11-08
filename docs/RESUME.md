# Resuming CUA-AgentOS

Written 2026-10-30, updated 2026-11-08 (chunk 5 done: transactions and recovery). Start here, then read `CLAUDE.md` (decisions, history) and `CUA-AgentOS_goal.md`
(product direction). Statuses below are dated evidence, not guarantees: recheck them before relying on them.

## Where things stand
- **Active branch:** `debian-base`. Product direction: Debian 13 + our packages (amd64, arm64), Pi 5 first.
- **Works on the real Pi 5:** the Debian image boots to the on-screen console (cage kiosk), and live Gemini tasks complete
  (36 `TASK_COMPLETE` lines in the 2026-10-30 debug log, about 2 hours of uptime).
- **Works in a VM:** `tests/test-debian-img.sh` passed 22/22 checks on the amd64 image (2026-10-30 18:07), including
  on-screen typing, simulated Wi-Fi, chat and the debug link.
- **The old Alpine/agent-init cycles:** all 8 passed earlier and stay as a record. On 2026-11-08 they were rebuilt from
  scratch and **really rebooted**: gates 01-08 all exit 0, rubric 100/100. `tests/regress.sh` also passes, but it only
  replays recorded logs.
- **Privileged broker (chunk 4), 2026-11-08:** `tests/test-debian-vm.sh` passed 24/24 (amd64 VM, including live Gemini). On the real Pi 5:
  bad requests rejected, `agentd` denied the approval socket, a Gemini-planned `cron` restart verified, and an on-screen `yes` restarted
  `NetworkManager`, with Wi-Fi returning and all phases in `/var/log/agentd-broker/audit.jsonl`.
- **Transactions and recovery (chunk 5), 2026-11-08:** `tests/test-txn-recovery.sh` passed 14/14 on the amd64 cloud image,
  including two QEMU power cuts (0.63 s and 2.93 s into live changes), 8 SIGKILLs inside real changes, every crafted
  interruption stage, and recovery at boot before systemd-timesyncd reads the file. See `docs/txn-chunk5-2026-11-08.md`.
  **Not yet done on hardware:** the real power pull on the Pi 5.
- **What the agent can do on Debian:** Tier 2 `tr`, the read tools (`date`, `uname`, `df`, `uptime`, `free`), chat,
  status/restart of three allowlisted services, and `config.set_ntp` (one of four compiled-in time servers, written as a
  transaction and confirmed by the daemon). It can make no other system change yet.

## Known gaps to remember
- **Images (2026-11-08):** both were rebuilt after the broker and chunk 5. amd64 passed `tests/test-debian-img.sh` 22/22
  (that run predates chunk 5 by two hours; the arm64 image has the newer `.deb`). The arm64 image at
  `build/debian-img/cua-agentos-pi5.img` has never been booted on hardware -- that is the next hardware step.
- **`build/` was wiped on 2026-11-08** down to the Pi image, `build/cross/` (the rootless cross tools, which no script
  recreates) and `build/debug/` (the debug link's key and token). Before running the VM tests again:
  `scripts/fetch-debian-cloud.sh` (the cloud image was deleted) and `scripts/build-deb.sh`; before gates 02-08,
  their builders. Evidence for the 2026-11-08 runs is kept in `build/evidence-2026-11-08/`.
- **Broker limits:** three services and two operations; restart counts live in memory and reset if the broker restarts.
- **Debug link on this network (2026-11-08):** laptop `192.168.1.4`, Pi `192.168.1.5`, neither reserved in the router (the Airtel page refused it). If either changes:
  rerun `debug-server.py card` for the laptop's address, and replace the `ufw` rule. The rule to remove when finished:
  `sudo ufw delete allow in on wlo1 proto tcp from 192.168.1.5 to 192.168.1.4 port 8443`. `serve` stops with the session that started it.
- **tty2 recovery has no usable login by default.** Root is locked unless the image is built with `ROOT_PASSWORD_HASH`
  (`tests/test-debian-img.sh` checks `root_locked`), so a default image has no working recovery login.
- **Image builds are not pinned.** `build-debian-img.sh` installs current Debian packages, so two builds can differ.
- **Chat memory is lost when agentd restarts.** Other persistence and update behaviour is undefined on Debian.
- **`debug-client` ships in the image** but does nothing unless `agentos-debug.env` is on the card. That file allows
  running commands as root from the laptop, so delete it from any card that is shared or used for real.

## What's left, in order (chunks are from `CUA-AgentOS_goal.md`)
1. **Privileged broker and approvals (chunk 4):** built on 2026-11-08 (see `CLAUDE.md`). `tests/test-debian-vm.sh` covers it. Add operations through its compiled-in table.
2. **One modifying Debian task with rollback (chunk 5):** done on 2026-11-08 (`config.set_ntp`), except the Pi power pull.
3. **Health checks and limited repair (chunk 6):** not started.
4. **Repeatable Pi 5 test procedure (chunk 7):** reboot, offline use, Wi-Fi loss, USB, shutdown, resource use, recorded.
5. **Fault injection on the Pi:** agentd crash, network loss, full disk, power loss.
6. **Updates and persistence:** define and test them.
7. **Pinned, reproducible image; a status doc** using implemented / partial / planned labels.
8. **After the first release (chunk 8):** app install, GUI automation, voice, local model, task history, more hardware.

## Next task: chunk 6 (brief for the next session)
**Before anything else:** the Pi 5 power pull (below). Chunk 5's exit criterion is only half met until a real board has
been interrupted; if it fails there, fix that before starting chunk 6.

**Goal (chunk 6):** a small set of deterministic health checks, each wired to one bounded, documented remedy. The model
may diagnose and choose; the policy stays in code, in the broker's compiled-in table.
1. **Pick the checks from what has actually gone wrong here:** the clock is not set (TLS fails, `CLOCK_WAIT`), there is
   no network or no DNS, the disk is nearly full, `agentd` or the kiosk is restarting in a loop, the planner is
   unreachable (429/503). Each check is one function with a true/false answer and no model involvement.
2. **One remedy per fault**, all through the broker, all reversible or idempotent: `config.set_ntp` already exists for
   the clock; a `NetworkManager` restart exists for the network. Anything new needs an entry in the compiled-in table.
3. **Bound everything:** at most one remedy per fault per run, a cap per hour, and no remedy at all for a fault the
   person was not told about. Reuse the 30 s cap and the restart window.
4. **Truthful reporting** on the screen and in the audit log: what was wrong, what was tried, whether it worked, and
   what was left alone. "Nothing was changed" must stay true when it is.
5. **Prove it** with fault injection in the VM (break DNS, fill the disk, stop timesyncd, kill agentd repeatedly) and
   then on the Pi. Exit criterion: detection, safe remedy or rollback, and truthful reporting, each shown by a check.

## The Pi 5 power pull (the owner has to do this)
Flash `build/debian-img/cua-agentos-pi5.img`, boot it, then on the screen (tty1):
1. `set the time server to time.cloudflare.com` -- it should answer that systemd-timesyncd confirms it.
2. Ask for it again with a different server from the list, and **pull the power while it is working**.
3. Boot again and ask `status`, then `set the time server to pool.ntp.org`.
Afterwards, over the debug link or on tty2: `/etc/systemd/timesyncd.conf.d/50-agentd-ntp.conf` must be a whole file
naming one allowlisted server, `/var/lib/agentd-broker/txn` must not exist, `systemctl status agentd-broker-recover`
must show `success`, and `/var/log/agentd-broker/audit.jsonl` must say what really happened (`recovered` if the cut
landed inside a change). Record the result in `docs/txn-chunk5-2026-11-08.md`.

## Getting the machine ready again
Not in git, because `build/` and `*.env` are ignored:
- `GEMINI_API_KEY.env`: a bare key with no `NAME=` prefix. Never print it. It was printed once in a session and should be
  rotated if that hasn't been done. Models get retired, so check `AGENTD_MODEL` in `CLAUDE.md` if calls start failing.
- `build/debug/`: the debug link's key and token. Regenerated if missing, but cards made with the old ones stop working.
- `build/cross/`: rootless cross tools. `build/debian-img/raspberrypi.gpg` is the Pi repo key, checked against a pinned
  fingerprint in the build script.

Host setup (Ubuntu 24.04):
```sh
sudo apt install mmdebstrap uidmap qemu-user-static mtools gcc-aarch64-linux-gnu
# Ubuntu blocks the user namespaces mmdebstrap needs. Undo:
#   sudo rm /etc/sysctl.d/60-userns.conf && sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=1
echo kernel.apparmor_restrict_unprivileged_userns=0 | sudo tee /etc/sysctl.d/60-userns.conf && sudo sysctl --system
```
Rust comes from rustup (`~/.cargo`). Ubuntu's `debian-archive-keyring` may lack the trixie keys. The VM test also needs
QEMU and OVMF.

## Common commands
```sh
tests/regress.sh                                   # fast check, no VM, under a minute
scripts/build-deb.sh                               # the .deb the VM tests install
scripts/fetch-debian-cloud.sh                      # the cloud image both VM tests boot
tests/test-debian-vm.sh                            # broker and service contract, 24 checks, about 1 min
tests/test-txn-recovery.sh                         # chunk 5: transactions, interruption, power cuts (CUTS=2), about 6 min
ARCH=amd64 scripts/build-debian-img.sh             # amd64 image
tests/test-debian-img.sh                           # boots it in a throwaway KVM guest; uses the live key
. build/cross/env.sh && ARCH=arm64 scripts/build-debian-img.sh   # Pi image, about 17 min
```

Put the Pi image on a card. Replace `sdX` after checking `lsblk`. The `test -b` guard matters: writing to an unplugged
`/dev/sda` once created a regular file there, and later flashes went into it.
```sh
test -b /dev/sdX && sudo dd if=build/debian-img/cua-agentos-pi5.img of=/dev/sdX bs=4M conv=fsync status=progress
```
Then copy the key onto the card's FAT partition, as `gemini.env` or a bare key file. First boot moves it to
`/etc/agentd/gemini.env` and removes it from the card. Wi-Fi is typed on screen with `wifi`, and is never stored on the card.

Debug link, to see and control the Pi from the laptop:
```sh
scripts/debug-server.py card /media/$USER/<FAT partition>   # adds agentos-debug.env to the card
scripts/debug-server.py serve                               # journal arrives in build/debug/pi.log
scripts/debug-server.py send 'systemctl status agentd'      # runs on the Pi as root
```
Without the link, the journal is copied to `agentos-journal.txt` on the FAT partition.

## Rules worth keeping
- Test amd64 only in a throwaway KVM guest (`-snapshot`), never on the laptop's disk. Real hardware means the Pi 5.
- Label emulator results separately, and don't claim a feature without test evidence.
- Keep the Alpine gates passing: they are the regression record.

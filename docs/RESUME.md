# Resuming CUA-AgentOS

Written 2026-10-30, when work paused. Start here, then read `CLAUDE.md` (decisions, history) and `CUA-AgentOS_goal.md`
(product direction). Statuses below are dated evidence, not guarantees: recheck them before relying on them.

## Where things stand
- **Active branch:** `debian-base`. Product direction: Debian 13 + our packages (amd64, arm64), Pi 5 first.
- **Works on the real Pi 5:** the Debian image boots to the on-screen console (cage kiosk), and live Gemini tasks complete
  (36 `TASK_COMPLETE` lines in the 2026-10-30 debug log, about 2 hours of uptime).
- **Works in a VM:** `tests/test-debian-img.sh` passed 22/22 checks on the amd64 image (2026-10-30 18:07), including
  on-screen typing, simulated Wi-Fi, chat and the debug link.
- **The old Alpine/agent-init cycles:** all 8 passed earlier and stay as a record. `tests/regress.sh` passed on 2026-10-30,
  but it only replays recorded logs. The real gates have not been rebooted since the latest `agentd` changes.
- **What the agent can do on Debian:** Tier 2 `tr`, the read tools (`date`, `uname`, `df`, `uptime`, `free`) and chat.
  It cannot change the system yet.

## Known gaps to remember
- **The Pi image is older than the code.** `build/debian-img/cua-agentos-pi5.img` was built at 17:04 and `agentd/src/main.rs`
  last changed at 18:01. Rebuild it before flashing.
- **tty2 recovery has no usable login by default.** Root is locked unless the image is built with `ROOT_PASSWORD_HASH`
  (`tests/test-debian-img.sh` checks `root_locked`), so a default image has no working recovery login.
- **Image builds are not pinned.** `build-debian-img.sh` installs current Debian packages, so two builds can differ.
- **Chat memory is lost when agentd restarts.** Other persistence and update behaviour is undefined on Debian.
- **`debug-client` ships in the image** but does nothing unless `agentos-debug.env` is on the card. That file allows
  running commands as root from the laptop, so delete it from any card that is shared or used for real.

## What's left, in order (chunks are from `CUA-AgentOS_goal.md`)
1. **Privileged broker and approvals (chunk 4):** not started. Begin with one safe action, such as restarting an
   allowlisted service. This is the recommended next step, and it unblocks the rest.
2. **One modifying Debian task with rollback (chunk 5):** the install journal in `agentd` is reusable, but only
   Alpine test packages use it.
3. **Health checks and limited repair (chunk 6):** not started.
4. **Repeatable Pi 5 test procedure (chunk 7):** reboot, offline use, Wi-Fi loss, USB, shutdown, resource use, recorded.
5. **Fault injection on the Pi:** agentd crash, network loss, full disk, power loss.
6. **Updates and persistence:** define and test them.
7. **Pinned, reproducible image; a status doc** using implemented / partial / planned labels.
8. **After the first release (chunk 8):** app install, GUI automation, voice, local model, task history, more hardware.

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

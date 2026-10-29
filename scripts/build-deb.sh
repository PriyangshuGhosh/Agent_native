#!/bin/sh
# Build build/deb/agentd_<version>_amd64.deb: agentd (glibc build) as a systemd service, for Debian 13 (trixie).
# No root needed. Tier 1 is not packaged: /run is noexec under systemd, and the service planner offers only Tier 2.
set -eu
umask 022

ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=$ROOT/build/deb
P=$B/pkg
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/agentd/Cargo.toml" | head -1)
export PATH=$HOME/.cargo/bin:$PATH SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1700000000}

CARGO_TARGET_DIR=$B/target cargo build -q --locked --release --target x86_64-unknown-linux-gnu --manifest-path "$ROOT/agentd/Cargo.toml"
rm -rf "$P" && mkdir -p "$P/DEBIAN" "$P/usr/bin" "$P/usr/lib/systemd/system" "$P/etc/agentd"
install -m 755 "$B/target/x86_64-unknown-linux-gnu/release/agentd" "$P/usr/bin/agentd"
install -m 644 "$ROOT/agentd/debian/agentd.service" "$P/usr/lib/systemd/system/agentd.service"
install -m 755 "$ROOT/agentd/debian/postinst" "$ROOT/agentd/debian/prerm" "$ROOT/agentd/debian/postrm" "$P/DEBIAN/"
chmod 700 "$P/etc/agentd" # gemini.env goes here; the key never ships in the package
cat >"$P/DEBIAN/control" <<CTL
Package: agentd
Version: $VERSION
Architecture: amd64
Maintainer: CUA-AgentOS <noreply@localhost>
Depends: libc6 (>= 2.39), curl, ca-certificates
Section: admin
Priority: optional
Description: CUA-AgentOS agent daemon
 Plans requests with Gemini, validates every directive against a fixed schema and allow-list,
 executes them as capped child processes and verifies each postcondition before reporting success.
CTL
find "$P" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
dpkg-deb --root-owner-group -Zxz --build "$P" "$B/agentd_${VERSION}_amd64.deb" >/dev/null
echo "$B/agentd_${VERSION}_amd64.deb"

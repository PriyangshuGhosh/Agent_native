#!/bin/sh
# Build build/deb/agentd_<version>_<arch>.deb: agentd (glibc build) as a systemd service, for Debian 13 (trixie).
# DEB_ARCH=amd64 (default) or arm64 (cross: needs aarch64-linux-gnu-gcc, e.g. `. build/cross/env.sh`). No root needed.
# Tier 1 is not packaged: /run is noexec under systemd, and the service planner offers only Tier 2.
set -eu
umask 022

ROOT=$(cd "$(dirname "$0")/.." && pwd)
B=$ROOT/build/deb
P=$B/pkg
DEB_ARCH=${DEB_ARCH:-amd64}
case $DEB_ARCH in
amd64) T=x86_64-unknown-linux-gnu ;;
arm64) T=aarch64-unknown-linux-gnu; export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc ;;
*) echo "build-deb: DEB_ARCH must be amd64 or arm64" >&2; exit 2 ;;
esac
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' "$ROOT/agentd/Cargo.toml" | head -1)
export PATH=$HOME/.cargo/bin:$PATH SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-1700000000}

CARGO_TARGET_DIR=$B/target cargo build -q --locked --release --target $T --manifest-path "$ROOT/agentd/Cargo.toml"
rm -rf "$P" && mkdir -p "$P/DEBIAN" "$P/usr/bin" "$P/usr/lib/systemd/system" "$P/etc/agentd"
install -m 755 "$B/target/$T/release/agentd" "$P/usr/bin/agentd"
install -m 644 "$ROOT/agentd/debian/agentd.service" "$ROOT/agentd/debian/agentd-console.service" \
	"$ROOT/agentd/debian/agentd.socket" "$P/usr/lib/systemd/system/"
install -m 755 "$ROOT/agentd/debian/postinst" "$ROOT/agentd/debian/prerm" "$ROOT/agentd/debian/postrm" "$P/DEBIAN/"
chmod 700 "$P/etc/agentd" # gemini.env goes here; the key never ships in the package
cat >"$P/DEBIAN/control" <<CTL
Package: agentd
Version: $VERSION
Architecture: $DEB_ARCH
Maintainer: CUA-AgentOS <noreply@localhost>
Depends: libc6 (>= 2.39), curl, ca-certificates, passwd
Section: admin
Priority: optional
Description: CUA-AgentOS agent daemon
 Plans requests with Gemini, validates every directive against a fixed schema and allow-list,
 executes them as capped child processes and verifies each postcondition before reporting success.
CTL
find "$P" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
dpkg-deb --root-owner-group -Zxz --build "$P" "$B/agentd_${VERSION}_$DEB_ARCH.deb" >/dev/null
echo "$B/agentd_${VERSION}_$DEB_ARCH.deb"

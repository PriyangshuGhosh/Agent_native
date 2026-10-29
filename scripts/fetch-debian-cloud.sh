#!/bin/sh
# Download the stock Debian 13 (trixie) amd64 cloud image into build/debian-cloud/, checked against Debian's SHA512SUMS.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
D=$ROOT/build/debian-cloud
U=https://cloud.debian.org/images/cloud/trixie/latest
IMG=debian-13-genericcloud-amd64.qcow2
mkdir -p "$D" && cd "$D"
curl -sSfL --connect-timeout 15 -O "$U/SHA512SUMS"
grep -q "  $IMG\$" SHA512SUMS
if ! grep "  $IMG\$" SHA512SUMS | sha512sum -c --quiet >/dev/null 2>&1; then
	curl -sSfL --connect-timeout 15 -o "$IMG.part" "$U/$IMG" && mv "$IMG.part" "$IMG"
	grep "  $IMG\$" SHA512SUMS | sha512sum -c --quiet
fi
echo "$D/$IMG"

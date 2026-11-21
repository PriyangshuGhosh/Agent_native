#!/bin/sh
# Goal 6, local model tier on the Raspberry Pi AI HAT+ 2 (Hailo-10H, its own 8 GB): run as root ON the Pi 5.
# Installs the Hailo-10H driver + runtime (Raspberry Pi archive) and Hailo's model server (hailo-ollama, pinned .deb),
# runs the server as its own unprivileged user on loopback only, pulls the model and points agentd at it.
# Idempotent. Measured on the user's Pi 2026-11-18 (docs/hailo-2026-11-18.md). Needs network.
# Not in the image on purpose: the HAT is optional, and the driver is built for the running kernel without DKMS,
# so after a kernel update rerun this script (shortcut: rebuild by hand; move to DKMS if Hailo's package gets it working).
set -eu
MODEL=${MODEL:-qwen2:1.5b}  # best of the HAT models on our requests (docs/hailo-2026-11-18.md)
ZOO=hailo_gen_ai_model_zoo_5.1.1_arm64.deb
ZOO_URL=https://dev-public.hailo.ai/2025_12/Hailo10/$ZOO
ZOO_SHA=17d5b476320b72ec199032e7a7b87ba72cb51311d56a9f0604213b7a9056deb9
MODELS=/usr/share/hailo-ollama/models
CONF=/etc/xdg/hailo-ollama/hailo-ollama.json

[ "$(id -u)" = 0 ] || { echo "setup-hailo: run as root on the Pi" >&2; exit 2; }
grep -qs 0x1e60 /sys/bus/pci/devices/*/vendor || { echo "setup-hailo: no Hailo device on PCIe (is the HAT seated?)" >&2; exit 1; }

# Only the driver and runtime: hailo-h10-all also pulls camera/OpenCV/GStreamer development stacks.
export DEBIAN_FRONTEND=noninteractive
apt-get install -y -q "linux-headers-$(uname -r)" h10-hailort h10-hailort-pcie-driver
modprobe hailo1x_pci
[ -e /dev/hailo0 ] || { echo "setup-hailo: driver loaded but no /dev/hailo0" >&2; exit 1; }

if ! dpkg -s hailo-gen-ai-model-zoo >/dev/null 2>&1; then
	curl -fsSL -o "/var/tmp/$ZOO" "$ZOO_URL"
	echo "$ZOO_SHA  /var/tmp/$ZOO" | sha256sum -c
	apt-get install -y -q "/var/tmp/$ZOO"
fi

# Shipped listening on 0.0.0.0: the model is for this machine only.
sed -i 's/"host": "0.0.0.0"/"host": "127.0.0.1"/' "$CONF"
grep -q '"host": "127.0.0.1"' "$CONF"

# Shipped world-writable (any local user could swap a model): owned by the server's own user instead.
id hailo-ollama >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /var/lib/hailo-ollama --shell /usr/sbin/nologin hailo-ollama
chown -R hailo-ollama:hailo-ollama "$MODELS"
chmod -R go-w "$MODELS"

cat >/etc/systemd/system/hailo-ollama.service <<'UNIT'
[Unit]
Description=Hailo-10H model server for agentd's local tier (loopback only)
After=network-online.target
Wants=network-online.target

[Service]
User=hailo-ollama
ExecStart=/usr/bin/hailo-ollama
StateDirectory=hailo-ollama
Environment=HOME=/var/lib/hailo-ollama
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ReadWritePaths=/usr/share/hailo-ollama/models
ProtectHome=yes
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
# The model lives in the HAT's own memory; the server itself stays small (measured: Pi RAM use did not grow).
MemoryMax=1G

[Install]
WantedBy=multi-user.target
UNIT
systemctl stop hailo-ollama-test 2>/dev/null || true
systemctl daemon-reload
systemctl enable -q hailo-ollama
systemctl restart hailo-ollama
for _ in $(seq 30); do curl -fs http://127.0.0.1:8000/hailo/v1/list >/dev/null && break; sleep 1; done
curl -fsS -H Content-Type:application/json http://127.0.0.1:8000/api/pull -d "{\"model\":\"$MODEL\",\"stream\":false}" --max-time 1800
echo

mkdir -p /etc/systemd/system/agentd.service.d
printf '[Service]\nEnvironment=AGENTD_LOCAL_URL=http://127.0.0.1:8000 AGENTD_LOCAL_MODEL=%s\n' "$MODEL" >/etc/systemd/system/agentd.service.d/local.conf
systemctl daemon-reload
systemctl restart agentd
sleep 2
agentd ask /status

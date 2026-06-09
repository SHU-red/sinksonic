#!/bin/bash
# SinkSonic — DietPi first-boot setup
# Runs automatically via AUTO_SETUP_CUSTOM_SCRIPT_EXEC in dietpi.txt.
# Downloads the Docker image from GitHub Container Registry.
set -euo pipefail

LOG="/var/log/sinksonic-firstboot.log"
exec > "$LOG" 2>&1

echo "[SinkSonic] Setup starting at $(date)"

# ── 1. PipeWire TCP listener ──────────────────────────────────────────────────
echo "[SinkSonic] Configuring PipeWire TCP..."
mkdir -p /etc/pipewire/pipewire-pulse.conf.d
cat > /etc/pipewire/pipewire-pulse.conf.d/10-network-tcp.conf << 'CONF'
pulse.cmd = [
    { cmd = "load-module"
      args = "module-native-protocol-tcp auth-anonymous=true"
      flags = [ nofail ] }
]
pulse.properties = { pulse.idle.timeout = 0 }
stream.properties = { resample.quality = 14 }
CONF
systemctl restart pipewire-pulse 2>/dev/null || true

# ── 2. Move Docker to writable partition ──────────────────────────────────────
echo "[SinkSonic] Moving Docker data to /mnt/dietpi_userdata/docker..."
mkdir -p /mnt/dietpi_userdata/docker
if [ -d /var/lib/docker ] && [ "$(ls -A /var/lib/docker 2>/dev/null)" ]; then
    cp -a /var/lib/docker/* /mnt/dietpi_userdata/docker/ 2>/dev/null || true
fi
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'CONF'
{ "data-root": "/mnt/dietpi_userdata/docker",
  "storage-driver": "overlay2",
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" } }
CONF
systemctl restart docker 2>/dev/null || true

# ── 3. Create sinksonic user ──────────────────────────────────────────────────
echo "[SinkSonic] Creating sinksonic user..."
if ! id sinksonic &>/dev/null; then
    useradd -m -G audio,video sinksonic
fi
loginctl enable-linger sinksonic 2>/dev/null || true

# ── 4. Pull and start SinkSonic container ─────────────────────────────────────
echo "[SinkSonic] Starting SinkSonic container..."
mkdir -p /mnt/dietpi_userdata/sinksonic
cd /mnt/dietpi_userdata/sinksonic

# Download compose file from public repo
curl -sSL -o docker-compose.yml \
    https://raw.githubusercontent.com/SHU-red/sinksonic/main/docker-compose.yml

# Pull pre-built image from GitHub Container Registry
docker compose pull 2>&1 && echo "[SinkSonic] Image pulled from GHCR" || \
    echo "[SinkSonic] WARNING: pull failed"

# Start the container
docker compose up -d 2>&1 || echo "[SinkSonic] WARNING: container start failed"

# ── 5. Enable read-only overlayfs ─────────────────────────────────────────────
echo "[SinkSonic] Enabling read-only overlayfs..."
/DietPi/dietpi/dietpi-overlay 1 2>/dev/null || \
    echo "[SinkSonic] WARNING: overlay enable failed — enable manually: dietpi-config → Advanced → Overlay"

echo "[SinkSonic] Setup done at $(date)"
echo "[SinkSonic] Web UI: http://SinkSonic.local:8080"

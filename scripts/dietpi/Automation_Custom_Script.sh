#!/bin/bash
# SinkSonic — DietPi first-boot setup
set -euo pipefail

LOG="/var/log/sinksonic-firstboot.log"
exec > "$LOG" 2>&1

echo "[SinkSonic] Setup starting at $(date)"
PIPEWIRE_USER="${PIPEWIRE_USER:-dietpi}"
PW_UID=$(id -u "$PIPEWIRE_USER")

# ── 1. PipeWire TCP config ────────────────────────────────────────────────────
echo "[SinkSonic] Configuring PipeWire TCP..."
mkdir -p /etc/pipewire/pipewire-pulse.conf.d
cat > /etc/pipewire/pipewire-pulse.conf.d/10-network-tcp.conf << 'CONF'
pulse.cmd = [{ cmd = "load-module" args = "module-native-protocol-tcp auth-anonymous=true" flags = [ nofail ] }]
pulse.properties = { pulse.idle.timeout = 0 }
stream.properties = { resample.quality = 14 }
CONF

# ── 2. User setup ─────────────────────────────────────────────────────────────
echo "[SinkSonic] Setting up user $PIPEWIRE_USER..."
usermod -aG audio,video "$PIPEWIRE_USER" 2>/dev/null || true
loginctl enable-linger "$PIPEWIRE_USER" 2>/dev/null || true

# ── 3. Systemd service: PipeWire at boot ──────────────────────────────────────
# Since PipeWire runs as a user service (needs login session), we create a
# system-level oneshot that starts it early via runsv/sudo on boot.
echo "[SinkSonic] Creating PipeWire boot service..."
cat > /etc/systemd/system/sinksonic-pipewire.service << UNIT
[Unit]
Description=SinkSonic PipeWire audio server
After=network.target sound.target
Before=sinksonic-webui.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/mkdir -p /run/user/$PW_UID
ExecStartPre=/bin/chown $PIPEWIRE_USER:$PIPEWIRE_USER /run/user/$PW_UID
ExecStartPre=/bin/chmod 700 /run/user/$PW_UID
ExecStart=/bin/su $PIPEWIRE_USER -c "XDG_RUNTIME_DIR=/run/user/$PW_UID pipewire & wireplumber & pipewire-pulse &"
ExecStop=/bin/pkill -u $PIPEWIRE_USER pipewire
ExecStop=/bin/pkill -u $PIPEWIRE_USER wireplumber
ExecStop=/bin/pkill -u $PIPEWIRE_USER pipewire-pulse

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable sinksonic-pipewire.service

# ── 4. Move Docker to writable partition ──────────────────────────────────────
echo "[SinkSonic] Moving Docker data to /mnt/dietpi_userdata/docker..."
mkdir -p /mnt/dietpi_userdata/docker /etc/docker
cat > /etc/docker/daemon.json << 'CONF'
{ "data-root": "/mnt/dietpi_userdata/docker", "storage-driver": "overlay2", "log-driver": "json-file", "log-opts": { "max-size": "10m", "max-file": "3" } }
CONF
systemctl restart docker 2>/dev/null || true

# ── 5. Systemd service: SinkSonic container at boot ──────────────────────────
echo "[SinkSonic] Creating SinkSonic boot service..."
mkdir -p /mnt/dietpi_userdata/sinksonic
cd /mnt/dietpi_userdata/sinksonic

# Download compose file
curl -sSL -o docker-compose.yml \
    https://raw.githubusercontent.com/SHU-red/sinksonic/main/docker-compose.yml

# Create override with correct UID
cat > docker-compose.override.yml << OVERRIDE
services:
  sinksonic:
    environment:
      - XDG_RUNTIME_DIR=/run/user/$PW_UID
    volumes:
      - sinksonic_data:/data
      - /run/user/$PW_UID:/run/user/$PW_UID:ro
      - /run/systemd:/run/systemd:rw
OVERRIDE

# Create systemd service for Docker Compose
cat > /etc/systemd/system/sinksonic-webui.service << UNIT
[Unit]
Description=SinkSonic Web UI
After=docker.service sinksonic-pipewire.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/mnt/dietpi_userdata/sinksonic
ExecStartPre=-/usr/bin/docker compose pull
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
StandardOutput=journal

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable sinksonic-webui.service

# ── 6. Start services now ─────────────────────────────────────────────────────
echo "[SinkSonic] Starting services..."
systemctl start sinksonic-pipewire.service 2>&1
sleep 3
systemctl start sinksonic-webui.service 2>&1
sleep 2

echo "[SinkSonic] Services status:"
systemctl is-active sinksonic-pipewire.service sinksonic-webui.service 2>&1

# ── 7. Enable read-only overlayfs ─────────────────────────────────────────────
echo "[SinkSonic] Enabling read-only overlayfs..."
if [ -f /DietPi/dietpi/dietpi-overlay ]; then
    /DietPi/dietpi/dietpi-overlay 1 2>/dev/null && echo "[SinkSonic] Overlay enabled" || echo "[SinkSonic] Overlay failed"
fi

echo "[SinkSonic] Setup done at $(date)"
echo "[SinkSonic] Web UI: http://SinkSonic.local"

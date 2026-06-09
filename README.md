# SinkSonic

Declarative network audio sink. Stream audio from any desktop to a device's audio output via PipeWire over TCP.

Works on **any Linux** — Raspberry Pi, x86, virtual machines. One Docker container, zero Nix required.

## Quick start

### Any Linux

```bash
curl -sSL https://raw.githubusercontent.com/SHU-red/sinksonic/main/scripts/setup.sh | sudo bash
```

### DietPi (zero-touch)

Copy the pre-configured config to the SD card **before first boot**:

```bash
# With SD card in your desktop:
cp scripts/dietpi/dietpi.txt /media/boot/dietpi.txt

# Or download it directly:
curl -sSL -o /media/boot/dietpi.txt \
  https://raw.githubusercontent.com/SHU-red/sinksonic/main/scripts/dietpi/dietpi.txt
```

Then insert the SD card into the device and power on. DietPi automatically:

1. Sets hostname to `sinksonic`
2. Installs Docker
3. Runs the post-install script — installs PipeWire, configures TCP, starts the container
4. Enables read-only overlayfs

After 5–10 minutes, SinkSonic is running at `http://sinksonic.local:8080`.

### Or manually

**1. Install dependencies**

```bash
# Debian / Raspberry Pi OS / Ubuntu
sudo apt install pipewire pipewire-pulse wireplumber pulseaudio-utils avahi-daemon docker.io

# Fedora
sudo dnf install pipewire pipewire-pulseaudio wireplumber pulseaudio-utils avahi docker
```

**2. Enable PipeWire PulseAudio TCP listener**

Copy `scripts/pipewire/10-network-tcp.conf` to `/etc/pipewire/pipewire-pulse.conf.d/`:

```bash
sudo mkdir -p /etc/pipewire/pipewire-pulse.conf.d
sudo cp scripts/pipewire/10-network-tcp.conf /etc/pipewire/pipewire-pulse.conf.d/
sudo systemctl restart pipewire-pulse
```

**3. Start SinkSonic**

```bash
docker compose up -d
```

## Web UI

Open `http://sinksonic.local:8080` (or the device's hostname/IP).

- Real-time audio stream monitoring
- Volume control per host
- Mute/unmute individual streams
- System status (CPU, RAM, temperature)
- Log viewer
- Reboot / poweroff

## Desktop setup (one time)

Create a tunnel sink that forwards audio to SinkSonic:

```bash
pactl load-module module-tunnel-sink \
  server=tcp:sinksonic.local:4713 \
  sink_name=sinksonic
```

Then select **SinkSonic** in your sound settings.

### Persistent (systemd user service)

```bash
cat > ~/.config/systemd/user/sinksonic-sink.service << 'EOF'
[Unit]
Description=SinkSonic network audio tunnel
After=pipewire-pulse.service
Wants=pipewire-pulse.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=bash -c 'pactl list modules short 2>/dev/null | grep module-tunnel-sink | awk \'{print $1}\' | xargs -r pactl unload-module'
ExecStart=pactl load-module module-tunnel-sink server=tcp:sinksonic.local:4713 sink_name=sinksonic
ExecStop=pactl unload-module $(pactl list modules short | grep module-tunnel-sink | awk '{print $1}')

[Install]
WantedBy=default.target
EOF
systemctl --user enable --now sinksonic-sink.service
```

## Architecture

```
Desktop                                Device (Linux)
────────                                ────────────────

  Any audio app ──► module-tunnel-sink ──► TCP:4713 ──► pipewire-pulse ──► wireplumber ──► Audio output
                    "SinkSonic"                                                         (3.5mm jack / HDMI)
                    (visible in Sound Settings)            ┌─────────────────────┐
                                                            │  SinkSonic Web UI   │
                                                            │  (Docker container)  │
                                                            │  Port 8080           │
                                                            │  /data (config)      │
                                                            └─────────────────────┘
```

## Configuration

All runtime config lives in `config/sinksonic.yaml`, mounted at `/data/sinksonic.yaml`.

| Setting | Default | Description |
|---|---|---|
| `audio.buffer_size` | 2048 | PipeWire quantum (frames). Larger = smoother, higher latency |
| `audio.sample_rate` | 48000 | Sample rate in Hz |
| `audio.resample_quality` | 14 | 1-14. 14 = best quality, higher CPU |
| `audio.latency_target_ms` | 10 | Target latency in ms |
| `network.interface` | eth0 | Network interface for DHCP |
| `network.dhcp` | true | Enable DHCP |
| `network.zeroconf` | true | Enable mDNS (Avahi) |
| `network.wifi.ssid` | — | WiFi SSID (optional, overrides Ethernet) |
| `network.wifi.password` | — | WiFi password |
| `webui.port` | 8080 | Web UI listen port |

## Build from source

```bash
docker build -t sinksonic-webui .
```

Or build the Go binary directly:

```bash
cd webui && CGO_ENABLED=0 go build -o sinksonic-webui .
```

## Filesystem layout (Pi)

```
SD Card:
  /boot       ── kernel, firmware (read-only)
  /           ── root filesystem (read-only, overlayfs)
  /data       ── persistent config (SinkSonic data volume)

Docker container:
  /           ── read-only (Alpine Linux)
  /data       ── writable volume (config, hosts.json)
  /tmp        ── tmpfs (16MB)
```

When using Raspberry Pi OS overlayfs, the SD card only sees writes to `/data`.

## License

MIT

# SinkSonic

Network audio sink. Stream audio from any desktop to a device's audio
output via PipeWire over TCP.

Works on **any Linux** — Raspberry Pi, x86, VM.
One DietPi config file, one Docker container.

## Quick start

### DietPi (recommended)

Copy **one file** to the SD card boot partition before first boot:

```bash
cp scripts/dietpi/dietpi.txt /media/boot/dietpi.txt
```

Insert SD card, power on. DietPi automatically:

1. Sets hostname to `SinkSonic`
2. Installs Docker + PipeWire + WirePlumber + Avahi
3. Downloads the setup script from GitHub
4. Starts PipeWire as system service
5. Pulls SinkSonic container from GHCR and starts it
6. Enables systemd services for reboot persistence

After ~5 minutes:
- **Web UI:** `http://SinkSonic.local`
- **SSH:** `ssh dietpi@SinkSonic.local` (password: `dietpi`)
- **Audio:** `pactl load-module module-tunnel-sink server=tcp:SinkSonic.local:4713`

### Updates

```bash
# SinkSonic only:
ssh dietpi@SinkSonic.local
cd /mnt/dietpi_userdata/sinksonic
docker compose pull && docker compose up -d

# System update (disable overlay first):
dietpi-config → Advanced → Overlay File System → disable
apt update && apt upgrade
dietpi-config → Advanced → Overlay File System → enable
reboot
```

### Any Linux (no DietPi)

```bash
curl -sSL https://raw.githubusercontent.com/SHU-red/sinksonic/main/scripts/setup.sh | sudo bash
```

## How it's built

Every push to `main` with changes to `Dockerfile` or `webui/` triggers
a GitHub Actions workflow that:

- Builds a multi-arch image (`linux/amd64`, `linux/arm64`)
- Publishes to `ghcr.io/shu-red/sinksonic/sinksonic-webui:latest`
- The DietPi first-boot script pulls this image automatically

## Files

```
sinksonic/
├── Dockerfile                          # Multi-stage Go build → 57MB Alpine image
├── docker-compose.yml                  # Compose config for container
├── .github/workflows/docker.yml        # CI: build + publish to GHCR
├── webui/                              # Go source (6MB static binary)
│   ├── main.go / handler.go / static/
├── config/sinksonic.yaml               # Runtime config template
├── scripts/
│   ├── setup.sh                        # One-liner for any Linux
│   ├── dietpi/
│   │   ├── dietpi.txt                  # ← THE ONLY FILE YOU COPY TO SD CARD
│   │   └── Automation_Custom_Script.sh # First-boot script (fetched from GitHub)
│   └── pipewire/
│       └── 10-network-tcp.conf         # PipeWire TCP listener config
└── LICENSE
```

## Configuration

Runtime settings in `/mnt/dietpi_userdata/sinksonic/sinksonic.yaml`:

| Setting | Default | Description |
|---|---|---|
| `audio.buffer_size` | 2048 | PipeWire quantum (frames). Larger = smoother |
| `audio.sample_rate` | 48000 | Sample rate in Hz |
| `audio.resample_quality` | 14 | 1–14. Higher = better quality, more CPU |
| `network.wifi.ssid` | — | WiFi SSID (optional, overrides Ethernet) |
| `network.wifi.password` | — | WiFi password |

## License

MIT

# ── SinkSonic: network audio sink web UI ──────────────────────────────────────
# Multi-stage build. Final image: ~15MB + PipeWire client libs.
#
# Build:
#   docker build -t sinksonic-webui .
#
# Run:
#   docker run --network=host -v /run/user/1000:/run/user/1000:ro \
#     -v sinksonic_data:/data sinksonic-webui

# ── Stage 1: build the Go binary ──────────────────────────────────────────────
FROM golang:1.26-alpine AS builder
WORKDIR /src
COPY webui/ .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o sinksonic-webui .

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM alpine:3.21

# PipeWire client tools — the web UI shells out to wpctl, pw-cli, pw-dump, pactl
RUN apk add --no-cache \
    pipewire \
    pipewire-pulse \
    pipewire-tools \
    pulseaudio-utils \
    wireplumber \
    ca-certificates

COPY --from=builder /src/sinksonic-webui /usr/local/bin/

VOLUME ["/data"]
EXPOSE 8080

ENV CONFIG_PATH=/data/sinksonic.yaml
ENV LISTEN_ADDR=0.0.0.0
ENV LISTEN_PORT=8080
ENV XDG_RUNTIME_DIR=/run/user/1000

CMD ["sinksonic-webui"]

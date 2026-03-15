# ASHMAN Broadcaster

macOS-based SDI-to-YouTube streaming appliance with a web dashboard for monitoring and control.

## Architecture

**Pipeline:**
```
SDI Input → Ingest (ffmpeg/DeckLink) → Multicast (239.20.0.10)
                                            │
                                            ├──→ Bridge (ffmpeg) → RTSP → MediaMTX → WebRTC/WHEP → Browser Preview
                                            │
                                            └──→ Uplink (ffmpeg) → RTMP → YouTube
```

**Services (LaunchDaemons):**

| Service | Script | Description |
|---------|--------|-------------|
| Ingest | `/usr/local/bin/yt_sdi_ingest.sh` | Captures SDI via DeckLink, outputs MPEG-TS multicast |
| Bridge | `/usr/local/bin/yt_bridge.sh` | Reads multicast, transcodes audio to Opus, pushes RTSP to MediaMTX |
| MediaMTX | `/usr/local/bin/start_mediamtx.sh` | RTSP server that serves WebRTC (WHEP) for low-latency browser preview |
| Uplink | `/usr/local/bin/yt_sdi_streamer.sh` | Reads multicast, encodes/remuxes to RTMP, pushes to YouTube |
| Dashboard | `/usr/local/bin/yt_dashboard.py` | Flask web UI (port 80) for monitoring, control, and multi-profile management |

**Shared:**
- `yt_common.sh` — Common functions sourced by ingest, bridge, and uplink
- `alerts/` — Alert and webhook scripts sourced by ingest and uplink
- `ytctl.sh` — Multi-service control CLI
- `/etc/yt-sdi-streamer.conf` — Main configuration (mode 600)
- `/etc/yt-sdi-streamer-profiles.json` — Stream profiles (low/standard/high)
- `newsyslog.yt-sdi-streamer.conf` — Log rotation config

## Dashboard Features

- **WebRTC Input Preview** — Low-latency SDI preview via WHEP (MediaMTX)
- **Audio VU Meter** — Real-time audio level meter
- **Control Bar** — Start/Stop/Restart broadcast with uptime display and live status indicator
- **Multi-Profile** — Switch between stream profiles (different bitrates, stream keys)
- **Pipeline Status** — Per-service health indicators (ingest, bridge, MediaMTX, uplink)
- **Broadcast Stats** — Mode, state, FPS, encoder bitrate, speed
- **Network Monitor** — Interface, IP, gateway, packet loss, latency, jitter
- **YouTube Playback Embed** — Embedded YouTube player for output monitoring

## Installed Paths (on Mac)

| Local | Deployed |
|-------|----------|
| `yt_sdi_ingest.sh` | `/usr/local/bin/yt_sdi_ingest.sh` |
| `yt_bridge.sh` | `/usr/local/bin/yt_bridge.sh` |
| `yt_sdi_streamer.sh` | `/usr/local/bin/yt_sdi_streamer.sh` |
| `yt_common.sh` | `/usr/local/bin/yt_common.sh` |
| `ytctl.sh` | `/usr/local/bin/ytctl` |
| `start_mediamtx.sh` | `/usr/local/bin/start_mediamtx.sh` |
| `mediamtx.yml` | `/usr/local/etc/mediamtx.yml` |
| `dashboard/app.py` | `/usr/local/bin/yt_dashboard.py` |
| `dashboard/static/*` | `/usr/local/lib/yt-dashboard/static/` |
| `dashboard/yt_dashboard_helper.sh` | `/usr/local/bin/yt_dashboard_helper.sh` |
| `yt-sdi-streamer.conf` | `/etc/yt-sdi-streamer.conf` (mode 600) |
| `*.plist` | `/Library/LaunchDaemons/` |
| `alerts/*` | `/usr/local/lib/yt-sdi-streamer/alerts/` |
| `newsyslog.yt-sdi-streamer.conf` | `/etc/newsyslog.d/yt-sdi-streamer.conf` |

## Deployment

```bash
# Deploy everything to Mac (from Linux dev machine)
./deploy.sh
```

To uninstall:
```bash
sudo ./uninstall_yt_sdi_streamer.sh           # Keep config
sudo ./uninstall_yt_sdi_streamer.sh --remove-config  # Remove everything
```

## Service Management

```bash
sudo ytctl start              # Start all services
sudo ytctl stop               # Stop all services
sudo ytctl uplink restart     # Restart uplink only
sudo ytctl ingest status      # Check ingest status
sudo ytctl bridge ffmpeg      # Follow bridge ffmpeg log
```

Or via the web dashboard at `http://<mac-ip>`

## FFmpeg Compilation (DeckLink + Opus + AAC)

```bash
export CPPFLAGS="-I/Users/kalaignarnetworks/include"
export CFLAGS="$CPPFLAGS"
export LDFLAGS="-L/Users/kalaignarnetworks/lib"
./configure --enable-gpl --enable-nonfree \
  --enable-decklink --enable-libfdk-aac \
  --enable-videotoolbox --enable-audiotoolbox \
  --enable-pthreads --enable-hardcoded-tables \
  --enable-version3 --enable-libfreetype \
  --enable-libfontconfig --enable-libopus \
  --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS"
```

## Resolved

- **Audio in input preview** (fixed 2026-03-14): Bridge audio changed from AAC to libopus. WebRTC natively supports Opus, so MediaMTX passes audio through to the browser without transcoding. VU meter now shows levels in the dashboard.

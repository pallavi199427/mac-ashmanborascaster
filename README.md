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
| Bridge | `/usr/local/bin/yt_bridge.sh` | Reads multicast, transcodes audio to AAC, pushes RTSP to MediaMTX |
| MediaMTX | `/usr/local/bin/start_mediamtx.sh` | RTSP server that serves WebRTC (WHEP) for low-latency browser preview |
| Uplink | `/usr/local/bin/yt_sdi_streamer.sh` | Reads multicast, encodes/remuxes to RTMP, pushes to YouTube |
| Dashboard | `/usr/local/bin/yt_dashboard.py` | Flask web UI (port 8080) for monitoring, control, and multi-profile management |

**Shared:**
- `yt_common.sh` — Common functions sourced by ingest, bridge, and uplink
- `ytctl.sh` — Multi-service control CLI
- `/etc/yt-sdi-streamer.conf` — Main configuration (mode 600)
- `/etc/yt-sdi-streamer-profiles.json` — Stream profiles (low/standard/high)

## Dashboard Features

- **WebRTC Input Preview** — Low-latency SDI preview via WHEP (MediaMTX)
- **Control Bar** — Start/Stop/Restart broadcast with live status indicator
- **Multi-Profile** — Switch between stream profiles (different bitrates, stream keys)
- **Pipeline Status** — Per-service health indicators (ingest, bridge, MediaMTX, uplink)
- **Broadcast Stats** — Mode, state, uptime, FPS, encoder bitrate, speed
- **Network Monitor** — Interface, IP, gateway, RX/TX rates, packet loss, latency, jitter
- **Event Log** — Real-time event stream with severity levels
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

## Service Management

```bash
sudo ytctl start              # Start all services
sudo ytctl stop               # Stop all services
sudo ytctl uplink restart     # Restart uplink only
sudo ytctl ingest status      # Check ingest status
sudo ytctl bridge ffmpeg      # Follow bridge ffmpeg log
```

Or via the web dashboard at `http://<mac-ip>:8080`

## FFmpeg Compilation (DeckLink support)

```bash
export CPPFLAGS="-I/Users/kalaignarnetworks/include"
export CFLAGS="$CPPFLAGS"
export LDFLAGS="-L/Users/kalaignarnetworks/lib"
./configure --enable-gpl --enable-nonfree --enable-decklink \
  --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS"
```

## Pending

- **Audio in input preview**: The WHEP preview currently has no working audio. The fix is to compile ffmpeg with libopus and use Opus audio in the bridge's RTSP stream to MediaMTX, so that the WebRTC/WHEP output to the browser carries audio natively (WebRTC prefers Opus over AAC).

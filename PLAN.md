# YT Appliance with MediaMTX — Implementation Plan

## Architecture

```
[DeckLink SDI] --> INGEST --> [UDP Multicast 239.20.0.10:5000]
                                    |
                                    +---> BRIDGE --> [RTSP :8554] --> MediaMTX --> [WebRTC :8889 WHEP] --> Browser Preview
                                    |
                                    +---> UPLINK --> [RTMP YouTube]
```

## File Structure

### Shared
- `yt_common.sh` — shared utility functions (logging, metrics, network, cleanup)

### New Files
| File | Purpose | Status |
|------|---------|--------|
| `yt_common.sh` | Shared utilities sourced by ingest + uplink | DONE |
| `yt_sdi_ingest.sh` | SDI → multicast (owns DeckLink, standby slate) | DONE |
| `yt_bridge.sh` | Multicast → RTSP → MediaMTX (~75 lines) | DONE |
| `start_mediamtx.sh` | macOS wrapper for MediaMTX (IP injection) | DONE |
| `mediamtx.yml` | MediaMTX config (WebRTC :8889, RTSP :8554) | DONE |
| `com.kalaignar.yt-ingest.plist` | LaunchDaemon for ingest | DONE |
| `com.kalaignar.yt-bridge.plist` | LaunchDaemon for bridge | DONE |
| `com.kalaignar.mediamtx.plist` | LaunchDaemon for MediaMTX | DONE |

### Modified Files
| File | Changes | Status |
|------|---------|--------|
| `yt_sdi_streamer.sh` | Refactor to uplink: remove DeckLink/standby, read multicast, remux to RTMP | DONE |
| `yt-sdi-streamer.conf` | Add MULTICAST_*, MEDIAMTX_*, UPLINK_REENCODE settings | DONE |
| `dashboard/app.py` | New endpoints (ingest/bridge status, pipeline), WebRTC video element | DONE |
| `dashboard/static/app.js` | WebRTC WHEP player, pipeline status dots | DONE |
| `dashboard/static/style.css` | Video preview styles | DONE |
| `ytctl.sh` | Multi-service support (ingest/bridge/mediamtx/uplink/dashboard) | DONE |
| `install_yt_sdi_streamer.sh` | Install new scripts, plists, mediamtx binary | DONE |
| `dashboard/install_dashboard.sh` | Sudoers for new service labels | DONE |

## Implementation Order

### Phase 1: Shared Library + Core Scripts
1. [x] Create `yt_bridge.sh`
2. [x] Create `start_mediamtx.sh` + `mediamtx.yml`
3. [x] Create all LaunchDaemon plists (ingest, bridge, mediamtx)
4. [x] Create `yt_common.sh` — extract shared functions from yt_sdi_streamer.sh
5. [x] Refactor `yt_sdi_ingest.sh` — source yt_common.sh, keep SDI/standby/probe logic
6. [x] Refactor `yt_sdi_streamer.sh` — source yt_common.sh, multicast input, remux to RTMP

### Phase 2: Config
7. [x] Update `yt-sdi-streamer.conf` — add multicast/mediamtx settings

### Phase 3: Dashboard
8. [x] Update `app.py` — new API endpoints, WebRTC video element in HTML
9. [x] Update `app.js` — WebRTC WHEP player, pipeline status polling
10. [x] Update `style.css` — video preview styles

### Phase 4: Service Management
11. [x] Update `ytctl.sh` — multi-service start/stop/restart/status

### Phase 5: Install & Deploy
12. [x] Update `install_yt_sdi_streamer.sh`
13. [x] Update `install_dashboard.sh`

## Key Decisions
- **Standby mode in ingest** — downstream always gets a stream
- **Uplink remuxes by default** (`-c:v copy -c:a copy`), optional re-encode via `UPLINK_REENCODE=true`
- **Keep old LaunchDaemon label** — `com.kalaignar.yt-sdi-streamer` for uplink
- **MediaMTX downloaded** as pre-built binary from GitHub releases (macOS arm64)
- **Bridge uses AAC** (not Opus) for macOS compatibility

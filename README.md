# ASHMAN Broadcast

macOS-based SDI-to-YouTube streaming appliance with a web dashboard for monitoring and control.

## Architecture

Two independent LaunchDaemons run on the Mac Mini:

```
┌──────────────────────────────────────────────────────┐
│  Mac Mini (macOS)                                    │
│                                                      │
│  ┌──────────────────┐    ┌────────────────────────┐  │
│  │  Streamer Daemon  │    │  Dashboard Daemon      │  │
│  │  (LaunchDaemon)   │    │  (LaunchDaemon :8080)  │  │
│  │                   │    │                        │  │
│  │  SDI input        │    │  Flask serves both:    │  │
│  │  → FFmpeg         │    │   • Web UI (HTML/JS)   │  │
│  │  → h264_videotb   │    │   • REST API (/api/*)  │  │
│  │  → RTMP/YouTube   │    │                        │  │
│  │                   │    │  Controls streamer via: │  │
│  │                   │◄───│   • sudo ytctl          │  │
│  │                   │    │   • sudo helper.sh      │  │
│  └──────────────────┘    └────────────────────────┘  │
│                                                      │
│  Config: /etc/yt-sdi-streamer.conf (shared)          │
└──────────────────────────────────────────────────────┘
```

The dashboard is a single Flask process that serves both the frontend (HTML/CSS/JS) and the backend API. It controls the streamer daemon via `sudo ytctl` and reads/writes config via `sudo yt_dashboard_helper.sh`.

## Components

| File | Purpose |
|------|---------|
| `yt_sdi_streamer.sh` | Main streaming daemon — captures SDI via FFmpeg, encodes with h264_videotoolbox, pushes RTMP to YouTube |
| `ytctl.sh` | Service control CLI (`start`, `stop`, `restart`, `status`) |
| `yt-sdi-streamer.conf` | Configuration file (bitrate, stream key, RTMP URL, playback URL) |
| `com.kalaignar.yt-sdi-streamer.plist` | macOS LaunchDaemon for the streamer service |
| `install_yt_sdi_streamer.sh` | Installer for the streamer daemon |
| `uninstall_yt_sdi_streamer.sh` | Uninstaller for the streamer daemon |
| `dashboard/app.py` | Flask web dashboard (HTML template embedded) |
| `dashboard/static/app.js` | Dashboard frontend JavaScript |
| `dashboard/static/style.css` | Dashboard CSS (glassmorphism dark theme) |
| `dashboard/yt_dashboard_helper.sh` | Privileged helper script for reading/writing config |
| `dashboard/install_dashboard.sh` | Dashboard installer (Flask, LaunchDaemon, sudoers) |
| `dashboard/uninstall_dashboard.sh` | Dashboard uninstaller |
| `dashboard/com.kalaignar.yt-dashboard.plist` | macOS LaunchDaemon for the dashboard |
| `alerts/alert.sh` | Alert notification script |
| `alerts/webhook.sh` | Webhook notification script |
| `newsyslog.yt-sdi-streamer.conf` | Log rotation configuration |

## Dashboard Features

- **Control Bar** — Start/Stop/Restart broadcast with live status indicator
- **Quality Presets** — Low (2500k), Standard (4000k), High (8000k) one-click bitrate selection
- **Configure Tab** — Edit video bitrate, stream key, and playback URL
- **Broadcast Status** — Mode, state, uptime, FPS, encoder bitrate, speed
- **Network Monitor** — Interface, IP, gateway, RX/TX rates, packet loss, latency, jitter
- **Event Log** — Real-time event stream with severity levels

## Deployment

Code is developed on Linux and deployed to the Mac via SCP.

### 1. Transfer files to Mac

```bash
# Dashboard files
scp dashboard/app.py         user@mac:~/yt-appliance/dashboard/
scp dashboard/static/app.js  user@mac:~/yt-appliance/dashboard/static/
scp dashboard/static/style.css user@mac:~/yt-appliance/dashboard/static/
scp dashboard/yt_dashboard_helper.sh user@mac:~/yt-appliance/dashboard/
scp dashboard/install_dashboard.sh   user@mac:~/yt-appliance/dashboard/
scp dashboard/com.kalaignar.yt-dashboard.plist user@mac:~/yt-appliance/dashboard/

# Streamer files
scp yt_sdi_streamer.sh       user@mac:~/yt-appliance/
scp ytctl.sh                 user@mac:~/yt-appliance/
scp install_yt_sdi_streamer.sh user@mac:~/yt-appliance/
```

### 2. Install / update on Mac

```bash
# Fix locale if needed (macOS Python issue)
export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8

# Install dashboard
sudo -E bash ~/yt-appliance/dashboard/install_dashboard.sh

# Install streamer (first time only)
sudo bash ~/yt-appliance/install_yt_sdi_streamer.sh
```

### 3. Verify deployment matches local

```bash
# Pull deployed files
scp user@mac:/usr/local/bin/yt_dashboard.py /tmp/mac-compare/app.py
scp user@mac:/usr/local/lib/yt-dashboard/static/app.js /tmp/mac-compare/app.js
scp user@mac:/usr/local/lib/yt-dashboard/static/style.css /tmp/mac-compare/style.css
scp user@mac:/usr/local/bin/yt_dashboard_helper.sh /tmp/mac-compare/yt_dashboard_helper.sh

# Diff
diff dashboard/app.py /tmp/mac-compare/app.py
diff dashboard/static/app.js /tmp/mac-compare/app.js
diff dashboard/static/style.css /tmp/mac-compare/style.css
diff dashboard/yt_dashboard_helper.sh /tmp/mac-compare/yt_dashboard_helper.sh
```

## Installed Paths (on Mac)

| Local | Deployed |
|-------|----------|
| `dashboard/app.py` | `/usr/local/bin/yt_dashboard.py` |
| `dashboard/static/*` | `/usr/local/lib/yt-dashboard/static/` |
| `dashboard/yt_dashboard_helper.sh` | `/usr/local/bin/yt_dashboard_helper.sh` |
| `yt_sdi_streamer.sh` | `/usr/local/bin/yt_sdi_streamer.sh` |
| `ytctl.sh` | `/usr/local/bin/ytctl` |
| `yt-sdi-streamer.conf` | `/etc/yt-sdi-streamer.conf` (mode 600) |

## Configuration

Edit `yt-sdi-streamer.conf` (or use the dashboard):

```bash
BITRATE_MAX_K="8000k"        # Max video bitrate
STREAM_KEY="xxxx-xxxx-xxxx"  # YouTube stream key (SECRET)
YOUTUBE_RTMP_URL="rtmp://a.rtmp.youtube.com/live2"
PLAYBACK_URL=""              # YouTube playback URL (future use)
```

## Service Management

```bash
# Via ytctl on Mac
sudo ytctl start
sudo ytctl stop
sudo ytctl restart
sudo ytctl status

# Or via the web dashboard at http://<mac-ip>:8080
```

## Notes

- Uses `h264_videotoolbox` (Apple Silicon hardware encoder)
- Helper script uses macOS `sed -i ''` syntax (not GNU)
- Regex in helper script stored in variables for bash 3.2 compatibility
- Config file is mode 600 (root-only) — cannot SCP directly
- LaunchDaemon: `com.kalaignar.yt-sdi-streamer` (streamer), `com.kalaignar.yt-dashboard` (dashboard)

compliatoin flags for decklink 
[11:20 am, 2/3/2026] Mani Vannan: export CPPFLAGS="-I/Users/kalaignarnetworks/include"
[11:20 am, 2/3/2026] Mani Vannan: export CFLAGS="$CPPFLAGS"
[11:20 am, 2/3/2026] Mani Vannan: export LDFLAGS="-L/Users/kalaignarnetworks/lib"
[11:20 am, 2/3/2026] Mani Vannan: ./configure --enable-gpl --enable-nonfree --enable-decklink \
  --extra-cflags="$CFLAGS" --extra-ldflags="$LDFLAGS"

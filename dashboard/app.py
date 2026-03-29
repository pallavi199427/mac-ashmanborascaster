#!/usr/bin/env python3
"""YT SDI Streamer — Web Dashboard"""

import json
import os
import re
import secrets
import subprocess
import time
from datetime import timedelta

# Fix for _www user having no accessible working directory
try:
    os.getcwd()
except (PermissionError, OSError):
    os.chdir("/tmp")

from flask import Flask, jsonify, redirect, render_template_string, request, session, url_for

# ---------- Configuration ----------
METRICS_PATH = "/var/log/yt-sdi-streamer/metrics.json"
STATUS_PATH = "/var/log/yt-sdi-streamer/status.json"
EVENTS_PATH = "/var/log/yt-sdi-streamer/events.jsonl"
INGEST_METRICS_PATH = "/var/log/yt-sdi-streamer/ingest_metrics.json"
INGEST_STATUS_PATH = "/var/log/yt-sdi-streamer/ingest_status.json"
INGEST_EVENTS_PATH = "/var/log/yt-sdi-streamer/ingest_events.jsonl"
BRIDGE_STATUS_PATH = "/var/log/yt-sdi-streamer/bridge_status.json"
YTCTL_PATH = "/usr/local/bin/ytctl"
HELPER_PATH = "/usr/local/bin/yt_dashboard_helper.sh"
DASHBOARD_PORT = 80

DASHBOARD_USER = "ashman"
DASHBOARD_PASS = "apple"

QUALITY_PRESETS = {
    "low":      {"label": "Low",      "bitrate": "2500k", "resolution": "1280x720",  "description": "Bandwidth friendly"},
    "standard": {"label": "Standard", "bitrate": "4000k", "resolution": "1920x1080", "description": "Recommended default"},
    "high":     {"label": "High",     "bitrate": "8000k", "resolution": "1920x1080", "description": "High quality"},
}

VALID_RESOLUTIONS = {"1920x1080", "1280x720"}

INSTALL_STATIC = "/usr/local/lib/yt-dashboard/static"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOCAL_STATIC = os.path.join(SCRIPT_DIR, "static")
STATIC_DIR = INSTALL_STATIC if os.path.isdir(INSTALL_STATIC) else LOCAL_STATIC

app = Flask(__name__, static_folder=STATIC_DIR)

# Use a stable secret key so sessions survive app restarts
_secret_key_path = "/var/lib/yt-dashboard/.secret_key"
def _load_or_create_secret_key():
    try:
        with open(_secret_key_path, "r") as f:
            key = f.read().strip()
            if key:
                return key
    except FileNotFoundError:
        pass
    key = secrets.token_hex(32)
    try:
        os.makedirs(os.path.dirname(_secret_key_path), mode=0o700, exist_ok=True)
        with open(_secret_key_path, "w") as f:
            f.write(key)
        os.chmod(_secret_key_path, 0o600)
    except OSError:
        pass
    return key

app.secret_key = os.environ.get("DASHBOARD_SECRET", _load_or_create_secret_key())
app.permanent_session_lifetime = timedelta(days=30)

# ---------- Helpers ----------

def read_json_file(path):
    """Read a JSON file and return parsed content, or None on error."""
    try:
        with open(path, "r") as f:
            raw = f.read().strip()
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            # Streamer bug: extra } after ffmpeg object e.g. "dup":0}},"switching"
            # Fix by replacing }}, with }, repeatedly until parseable
            fixed = raw
            while "}}," in fixed:
                fixed = fixed.replace("}},", "},")
                try:
                    return json.loads(fixed)
                except json.JSONDecodeError:
                    continue
            return None
    except (FileNotFoundError, OSError):
        return None


def read_last_lines(path, n=50):
    """Read the last N lines of a file efficiently."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            block_size = min(size, n * 512)
            f.seek(max(0, size - block_size))
            data = f.read().decode("utf-8", errors="replace")
            lines = data.strip().split("\n")
            return lines[-n:]
    except (FileNotFoundError, OSError):
        return []


def run_sudo(cmd, timeout=30):
    """Run a command with sudo, return (ok, output)."""
    try:
        result = subprocess.run(
            ["sudo"] + cmd,
            capture_output=True, text=True, timeout=timeout
        )
        if result.returncode == 0:
            return True, result.stdout.strip()
        return False, result.stderr.strip() or f"Exit code {result.returncode}"
    except subprocess.TimeoutExpired:
        return False, "Command timed out"
    except Exception as e:
        return False, str(e)


LAUNCHD_LABELS = {
    "uplink": "com.kalaignar.yt-sdi-streamer",
    "ingest": "com.kalaignar.yt-ingest",
    "bridge": "com.kalaignar.yt-bridge",
    "mediamtx": "com.kalaignar.mediamtx",
}
# Keep backwards compat
LAUNCHD_LABEL = LAUNCHD_LABELS["uplink"]
SERVICE_CACHE_TTL = 5  # seconds

_service_cache = {}  # label -> {"running": bool, "checked_at": float}

def is_service_running(label=None):
    """Check if a LaunchDaemon is loaded and running (cached for 5s)."""
    if label is None:
        label = LAUNCHD_LABEL
    now = time.monotonic()
    cached = _service_cache.get(label, {"running": False, "checked_at": 0.0})
    if now - cached["checked_at"] < SERVICE_CACHE_TTL:
        return cached["running"]
    try:
        result = subprocess.run(
            ["sudo", "launchctl", "print", f"system/{label}"],
            capture_output=True, text=True, timeout=5
        )
        running = result.returncode == 0
    except Exception:
        running = False
    _service_cache[label] = {"running": running, "checked_at": now}
    return running


# ---------- Authentication ----------

def load_dashboard_creds():
    """Load dashboard credentials from config via helper script."""
    global DASHBOARD_USER, DASHBOARD_PASS
    try:
        ok, output = run_sudo([HELPER_PATH, "read-dashboard-creds"])
        if ok and output.strip():
            lines = output.strip().split("\n")
            if len(lines) >= 2:
                DASHBOARD_USER = lines[0]
                DASHBOARD_PASS = lines[1]
    except Exception:
        pass

load_dashboard_creds()


@app.before_request
def require_login():
    allowed = ("/login", "/static/")
    if any(request.path.startswith(p) for p in allowed):
        return
    if not session.get("logged_in"):
        if request.path.startswith("/api/"):
            return jsonify({"error": "Not authenticated"}), 401
        return redirect(url_for("login"))


LOGIN_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ASHMAN Broadcast — Login</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@500;600;700&display=swap" rel="stylesheet">
  <link rel="stylesheet" href="/static/style.css">
</head>
<body class="login-body">
  <div class="login-card">
    <div class="login-logo">
      <div class="logo-icon">AB</div>
      <h1>ASHMAN Broadcast</h1>
    </div>
    {% if error %}
    <div class="login-error">{{ error }}</div>
    {% endif %}
    <form method="POST" action="/login">
      <div class="login-field">
        <label for="username">Username</label>
        <input type="text" id="username" name="username" autocomplete="username" required autofocus>
      </div>
      <div class="login-field">
        <label for="password">Password</label>
        <input type="password" id="password" name="password" autocomplete="current-password" required>
      </div>
      <button type="submit" class="login-btn">Login</button>
    </form>
  </div>
</body>
</html>"""


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        username = request.form.get("username", "")
        password = request.form.get("password", "")
        if username == DASHBOARD_USER and password == DASHBOARD_PASS:
            session.permanent = True
            session["logged_in"] = True
            return redirect(url_for("index"))
        return render_template_string(LOGIN_HTML, error="Invalid credentials")
    return render_template_string(LOGIN_HTML, error=None)


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


# ---------- API Routes ----------

@app.route("/api/metrics")
def api_metrics():
    data = read_json_file(METRICS_PATH)
    running = is_service_running()
    if data is None:
        return jsonify({"error": "No metrics data available", "service_running": running}), 503
    data["service_running"] = running
    return jsonify(data)


@app.route("/api/status")
def api_status():
    data = read_json_file(STATUS_PATH)
    if data is None:
        return jsonify({"error": "No status data available"}), 503
    return jsonify(data)


@app.route("/api/events")
def api_events():
    n = request.args.get("n", 50, type=int)
    n = min(max(n, 1), 500)
    lines = read_last_lines(EVENTS_PATH, n)
    events = []
    for line in lines:
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return jsonify(events)


@app.route("/api/pipeline")
def api_pipeline():
    """Return status of all pipeline services."""
    pipeline = {}
    for svc, label in LAUNCHD_LABELS.items():
        pipeline[svc] = {"running": is_service_running(label)}
    # Add ingest metrics if available
    ingest_metrics = read_json_file(INGEST_METRICS_PATH)
    if ingest_metrics:
        pipeline["ingest"]["metrics"] = ingest_metrics
    # Add bridge status if available
    bridge_status = read_json_file(BRIDGE_STATUS_PATH)
    if bridge_status:
        pipeline["bridge"]["status"] = bridge_status
    # Add uplink metrics if available
    uplink_metrics = read_json_file(METRICS_PATH)
    if uplink_metrics:
        pipeline["uplink"]["metrics"] = uplink_metrics
    return jsonify(pipeline)


@app.route("/api/ingest/metrics")
def api_ingest_metrics():
    data = read_json_file(INGEST_METRICS_PATH)
    running = is_service_running(LAUNCHD_LABELS["ingest"])
    if data is None:
        return jsonify({"error": "No ingest metrics available", "service_running": running}), 503
    data["service_running"] = running
    return jsonify(data)


@app.route("/api/ingest/status")
def api_ingest_status():
    data = read_json_file(INGEST_STATUS_PATH)
    if data is None:
        return jsonify({"error": "No ingest status available"}), 503
    return jsonify(data)


@app.route("/api/ingest/events")
def api_ingest_events():
    n = request.args.get("n", 50, type=int)
    n = min(max(n, 1), 500)
    lines = read_last_lines(INGEST_EVENTS_PATH, n)
    events = []
    for line in lines:
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError:
            continue
    return jsonify(events)


@app.route("/api/bridge/status")
def api_bridge_status():
    data = read_json_file(BRIDGE_STATUS_PATH)
    running = is_service_running(LAUNCHD_LABELS["bridge"])
    if data is None:
        return jsonify({"error": "No bridge status available", "service_running": running}), 503
    data["service_running"] = running
    return jsonify(data)


@app.route("/api/stream-key", methods=["GET"])
def api_get_stream_key():
    ok, output = run_sudo([HELPER_PATH, "read-key"])
    if not ok:
        return jsonify({"error": output}), 500
    key = output.strip()
    reveal = request.args.get("reveal", "false").lower() == "true"
    if reveal:
        return jsonify({"key": key, "masked": False})
    if len(key) > 4:
        masked = "*" * (len(key) - 4) + key[-4:]
    else:
        masked = "****"
    return jsonify({"key": masked, "masked": True})


@app.route("/api/stream-key", methods=["POST"])
def api_set_stream_key():
    data = request.get_json(silent=True)
    if not data or "key" not in data:
        return jsonify({"error": "Missing 'key' in request body"}), 400
    key = data["key"].strip()
    if not re.match(r"^[a-zA-Z0-9-]{4,64}$", key):
        return jsonify({"error": "Invalid key format (alphanumeric and dashes, 4-64 chars)"}), 400
    ok, output = run_sudo([HELPER_PATH, "write-key", key])
    if not ok:
        return jsonify({"error": output}), 500
    return jsonify({"ok": True, "message": "Stream key updated. Restart the service for it to take effect."})


@app.route("/api/bitrate", methods=["GET"])
def api_get_bitrate():
    ok, output = run_sudo([HELPER_PATH, "read-bitrate"])
    if not ok:
        return jsonify({"error": output}), 500
    return jsonify({"bitrate": output.strip()})


@app.route("/api/bitrate", methods=["POST"])
def api_set_bitrate():
    data = request.get_json(silent=True)
    if not data or "bitrate" not in data:
        return jsonify({"error": "Missing 'bitrate' in request body"}), 400
    bitrate = data["bitrate"].strip()
    if not re.match(r"^[0-9]{1,6}k?$", bitrate):
        return jsonify({"error": "Invalid bitrate format (e.g. 4000k)"}), 400
    if not bitrate.endswith("k"):
        bitrate = bitrate + "k"
    ok, output = run_sudo([HELPER_PATH, "write-bitrate", bitrate])
    if not ok:
        return jsonify({"error": output}), 500
    return jsonify({"ok": True, "message": "Bitrate updated. Restart the service for it to take effect."})


@app.route("/api/resolution", methods=["GET"])
def api_get_resolution():
    ok, output = run_sudo([HELPER_PATH, "read-resolution"])
    if not ok:
        return jsonify({"error": output}), 500
    return jsonify({"resolution": output.strip()})


@app.route("/api/resolution", methods=["POST"])
def api_set_resolution():
    data = request.get_json(silent=True)
    if not data or "resolution" not in data:
        return jsonify({"error": "Missing 'resolution' in request body"}), 400
    resolution = data["resolution"].strip()
    if resolution not in VALID_RESOLUTIONS:
        return jsonify({"error": f"Invalid resolution. Allowed: {', '.join(sorted(VALID_RESOLUTIONS))}"}), 400
    ok, output = run_sudo([HELPER_PATH, "write-resolution", resolution])
    if not ok:
        return jsonify({"error": output}), 500
    return jsonify({"ok": True, "message": "Resolution updated. Restart the service for it to take effect."})


@app.route("/api/presets")
def api_get_presets():
    return jsonify(QUALITY_PRESETS)


@app.route("/api/playback-url", methods=["GET"])
def api_get_playback_url():
    ok, output = run_sudo([HELPER_PATH, "read-playback-url"])
    if not ok:
        return jsonify({"error": output}), 500
    return jsonify({"url": output.strip()})


@app.route("/api/playback-url", methods=["POST"])
def api_set_playback_url():
    data = request.get_json(silent=True)
    if not data or "url" not in data:
        return jsonify({"error": "Missing 'url' in request body"}), 400
    url = data["url"].strip()
    if url and not re.match(r"^https?://[a-zA-Z0-9._:/?&=%@+~#-]+$", url):
        return jsonify({"error": "Invalid URL format (must start with http:// or https://)"}), 400
    ok, output = run_sudo([HELPER_PATH, "write-playback-url", url])
    if not ok:
        return jsonify({"error": output}), 500
    return jsonify({"ok": True, "message": "Playback URL updated."})


@app.route("/api/network", methods=["GET"])
def api_get_network():
    ok, output = run_sudo([HELPER_PATH, "read-network"])
    if not ok:
        return jsonify({"error": output}), 500
    try:
        return jsonify(json.loads(output))
    except json.JSONDecodeError:
        return jsonify({"error": "Invalid network data"}), 500


@app.route("/api/network", methods=["POST"])
def api_set_network():
    data = request.get_json(silent=True)
    if not data or "service" not in data:
        return jsonify({"error": "Missing 'service' in request body"}), 400
    ok, output = run_sudo([HELPER_PATH, "write-network", json.dumps(data)])
    if not ok:
        return jsonify({"ok": False, "error": output}), 500
    return jsonify({"ok": True, "message": "Network settings applied"})


@app.route("/api/control", methods=["POST"])
def api_control():
    data = request.get_json(silent=True)
    if not data or "action" not in data:
        return jsonify({"error": "Missing 'action' in request body"}), 400
    action = data["action"]
    if action not in ("start", "stop", "restart"):
        return jsonify({"error": "Invalid action. Use start, stop, or restart."}), 400
    service = data.get("service", "all")
    if service not in ("all", "ingest", "bridge", "mediamtx", "uplink", "dashboard"):
        return jsonify({"error": "Invalid service"}), 400
    ok, output = run_sudo([YTCTL_PATH, service, action])
    if not ok:
        return jsonify({"ok": False, "error": output}), 500
    return jsonify({"ok": True, "output": output})


@app.route("/api/profiles", methods=["GET"])
def api_get_profiles():
    ok, output = run_sudo([HELPER_PATH, "read-profiles"])
    if not ok:
        return jsonify({"error": output}), 500
    try:
        return jsonify(json.loads(output))
    except json.JSONDecodeError:
        return jsonify({"error": "Invalid profiles data"}), 500


@app.route("/api/profiles/<profile_id>", methods=["POST"])
def api_save_profile(profile_id):
    data = request.get_json(silent=True)
    if not data:
        return jsonify({"error": "Missing request body"}), 400
    # Read current profiles
    ok, output = run_sudo([HELPER_PATH, "read-profiles"])
    if not ok:
        return jsonify({"error": output}), 500
    try:
        profiles = json.loads(output)
    except json.JSONDecodeError:
        return jsonify({"error": "Invalid profiles data"}), 500
    if profile_id not in profiles.get("profiles", {}):
        return jsonify({"error": "Profile not found"}), 404
    # Validate optional fields
    if "resolution" in data and data["resolution"] not in VALID_RESOLUTIONS:
        return jsonify({"error": f"Invalid resolution. Allowed: {', '.join(sorted(VALID_RESOLUTIONS))}"}), 400
    if "bitrate" in data and not re.match(r"^[0-9]{1,6}k?$", data["bitrate"]):
        return jsonify({"error": "Invalid bitrate format (e.g. 4000k)"}), 400
    # Update fields
    p = profiles["profiles"][profile_id]
    for field in ("name", "platform", "stream_key", "bitrate", "playback_url", "resolution"):
        if field in data:
            val = data[field]
            # Ensure bitrate always has 'k' suffix (ffmpeg treats bare number as bits)
            if field == "bitrate" and val and not val.endswith("k"):
                val = val + "k"
            p[field] = val
    profiles["profiles"][profile_id] = p
    # Write back
    ok, output = run_sudo([HELPER_PATH, "write-profile", json.dumps(profiles)])
    if not ok:
        return jsonify({"error": output}), 500
    # If this is the active profile, also sync to .conf
    if profiles.get("active") == profile_id:
        run_sudo([HELPER_PATH, "switch-profile", profile_id])
    return jsonify({"ok": True})


@app.route("/api/profiles/switch", methods=["POST"])
def api_switch_profile():
    data = request.get_json(silent=True)
    if not data or "profile_id" not in data:
        return jsonify({"error": "Missing 'profile_id'"}), 400
    profile_id = data["profile_id"]
    ok, output = run_sudo([HELPER_PATH, "switch-profile", profile_id])
    if not ok:
        return jsonify({"error": output}), 500
    return jsonify({"ok": True, "message": "Profile switched. Restart for changes to take effect."})


# ---------- Frontend ----------

HTML = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>ASHMAN Broadcast</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;450;500;600;700&family=JetBrains+Mono:wght@500;600;700&display=swap" rel="stylesheet">
  <link rel="stylesheet" href="/static/style.css">
</head>
<body>

  <!-- Header Bar -->
  <header class="header">
    <div class="header-left">
      <div class="logo-icon">AB</div>
      <h1>ASHMAN Broadcast</h1>
    </div>
    <div class="header-center">
      <div class="status-group">
        <span>INGEST</span><span class="status-dot" id="dot-ingest"></span>
      </div>
      <div class="status-group">
        <span>HUB</span><span class="status-dot ok" id="dot-hub"></span>
      </div>
      <div class="status-group">
        <span>UPLINK</span><span class="status-dot" id="dot-uplink"></span>
      </div>
    </div>
    <div class="header-right">
      <span class="header-clock" id="headerClock">--:--:--</span>
      <a href="/logout" class="logout-btn" title="Logout">Logout</a>
    </div>
  </header>

  <!-- Mobile Status Strip (hidden on desktop) -->
  <div class="mobile-status-strip">
    <div class="status-group">
      <span>INGEST</span><span class="status-dot" id="dot-ingest-m"></span>
    </div>
    <div class="status-group">
      <span>HUB</span><span class="status-dot ok" id="dot-hub-m"></span>
    </div>
    <div class="status-group">
      <span>UPLINK</span><span class="status-dot" id="dot-uplink-m"></span>
    </div>
  </div>

  <!-- Control Bar -->
  <div class="control-bar">
    <div class="control-left">
      <span class="uptime-display" id="s-uptime">00:00:00</span>
    </div>
    <div class="control-center">
      <span class="broadcast-dot stopped" id="broadcastDot"></span>
      <span class="broadcast-label" id="broadcastLabel">BROADCAST: STOPPED</span>
    </div>
    <div class="control-right">
      <button class="btn-restart-sm" id="btn-restart" disabled onclick="ctrlAction('restart')">Restart</button>
      <button class="btn-golive" id="btn-golive" disabled onclick="ctrlAction('start')">GO LIVE</button>
      <button class="btn-stoplive" id="btn-stoplive" style="display:none" disabled onclick="ctrlAction('stop')">STOP</button>
    </div>
  </div>

  <!-- Main Content: Two-Column -->
  <div class="main-content">

    <!-- Left Panel -->
    <div class="left-panel">
      <!-- Input Preview (WebRTC via MediaMTX WHEP) -->
      <div class="preview-area">
        <div class="preview-header">
          <span>INPUT PREVIEW</span>
          <div class="preview-badge">
            <span class="preview-info" id="previewInfo">WebRTC</span>
            <span class="badge-live" id="previewLive" style="display:none">LIVE</span>
          </div>
        </div>
        <div class="preview-content">
          <video id="previewVideo" autoplay muted playsinline></video>
          <div class="preview-overlay" id="previewOverlay">NO PREVIEW</div>
          <!-- Audio VU Meter -->
          <div class="vu-meter" id="vuMeter">
            <button class="vu-mute-btn" id="muteBtn" title="Unmute audio" onclick="toggleMute()">
              <svg viewBox="0 0 24 24" fill="currentColor"><path d="M16.5 12c0-1.77-1.02-3.29-2.5-4.03v2.21l2.45 2.45c.03-.2.05-.41.05-.63zm2.5 0c0 .94-.2 1.82-.54 2.64l1.51 1.51C20.63 14.91 21 13.5 21 12c0-4.28-2.99-7.86-7-8.77v2.06c2.89.86 5 3.54 5 6.71zM4.27 3L3 4.27 7.73 9H3v6h4l5 5v-6.73l4.25 4.25c-.67.52-1.42.93-2.25 1.18v2.06c1.38-.31 2.63-.95 3.69-1.81L19.73 21 21 19.73l-9-9L4.27 3zM12 4L9.91 6.09 12 8.18V4z"/></svg>
            </button>
          </div>
        </div>
      </div>
      <!-- Playback Embed -->
      <div class="playback-area">
        <div class="playback-header" id="playbackHeader" style="display:none">
          <span class="playback-title">YOUTUBE LIVE</span>
        </div>
        <div class="playback-embed" id="playbackEmbed" style="display:none"></div>
        <span class="playback-placeholder" id="playbackPlaceholder">START BROADCAST TO VIEW STREAM</span>
      </div>
    </div>

    <!-- Right Sidebar -->
    <div class="right-sidebar">

      <!-- Stream Profiles (rendered dynamically by JS) -->
      <div class="sidebar-panel">
        <div class="panel-header">
          <span class="panel-title">STREAM PROFILES</span>
        </div>
        <div id="profilesList"></div>
      </div>
      <!-- Broadcast Status -->
      <div class="sidebar-panel">
        <div class="panel-header">
          <span class="panel-title">BROADCAST STATUS</span>
        </div>
        <div class="panel-body">
          <div class="stat-row"><span class="stat-label">Mode</span><span class="stat-value" id="s-mode">-</span></div>
          <div class="stat-row"><span class="stat-label">State</span><span class="stat-value" id="s-state">-</span></div>
          <div class="stat-row"><span class="stat-label">Bitrate</span><span class="stat-value" id="s-bitrate">-</span></div>
          <div class="stat-row"><span class="stat-label">FPS</span><span class="stat-value" id="s-fps">-</span></div>
          <div class="stat-row"><span class="stat-label">Speed</span><span class="stat-value" id="s-speed">-</span></div>
          <div class="stat-row"><span class="stat-label">Last Update</span><span class="stat-value" id="s-ts">-</span></div>
        </div>
      </div>

      <!-- Network -->
      <div class="sidebar-panel">
        <div class="panel-header">
          <span class="panel-title">NETWORK</span>
          <button class="btn-icon" id="btn-net-config" onclick="openNetConfig()" title="Configure network">&#9881;</button>
        </div>
        <div class="panel-body" id="net-stats">
          <div class="stat-row"><span class="stat-label">Interface</span><span class="stat-value" id="n-iface">-</span></div>
          <div class="stat-row"><span class="stat-label">IP Address</span><span class="stat-value" id="n-ip">-</span></div>
          <div class="stat-row"><span class="stat-label">Gateway</span><span class="stat-value" id="n-gw">-</span></div>
          <div class="stat-row"><span class="stat-label">Packet Loss</span><span class="stat-value" id="n-loss">-</span></div>
          <div class="stat-row"><span class="stat-label">Latency</span><span class="stat-value" id="n-avg">-</span></div>
          <div class="stat-row"><span class="stat-label">Jitter</span><span class="stat-value" id="n-jitter">-</span></div>
        </div>
        <div class="panel-body net-config-form" id="net-config" style="display:none">
          <div class="form-group">
            <label class="form-label">Interface</label>
            <select id="nc-iface" class="form-input"></select>
          </div>
          <div class="form-group">
            <label class="form-label">Mode</label>
            <div class="radio-group">
              <label class="radio-label"><input type="radio" name="nc-mode" value="dhcp" checked onchange="toggleNetMode()"> DHCP</label>
              <label class="radio-label"><input type="radio" name="nc-mode" value="static" onchange="toggleNetMode()"> Static</label>
            </div>
          </div>
          <div id="nc-static-fields">
            <div class="form-group">
              <label class="form-label">IP Address</label>
              <input type="text" id="nc-ip" class="form-input" placeholder="192.168.1.100">
            </div>
            <div class="form-group">
              <label class="form-label">Subnet Mask</label>
              <input type="text" id="nc-subnet" class="form-input" placeholder="255.255.255.0">
            </div>
            <div class="form-group">
              <label class="form-label">Gateway</label>
              <input type="text" id="nc-gateway" class="form-input" placeholder="192.168.1.1">
            </div>
          </div>
          <div class="form-group">
            <label class="form-label">DNS Servers</label>
            <input type="text" id="nc-dns" class="form-input" placeholder="1.1.1.1, 8.8.8.8">
          </div>
          <div class="form-actions">
            <button class="btn-apply" onclick="applyNetConfig()">Apply</button>
            <button class="btn-cancel" onclick="closeNetConfig()">Cancel</button>
          </div>
          <div class="form-status" id="nc-status"></div>
        </div>
      </div>


    </div>
  </div>

  <!-- Confirmation Modal -->
  <div class="modal-backdrop" id="confirmModal">
    <div class="modal-content">
      <h3>Confirm</h3>
      <p id="confirmMsg">Are you sure?</p>
      <div class="modal-actions">
        <button class="btn-cancel" onclick="hideConfirmModal()">Cancel</button>
        <button class="btn-confirm-stop" id="confirmBtn">Confirm</button>
      </div>
    </div>
  </div>

  <div class="toast" id="toast"></div>

  <script src="/static/app.js"></script>
</body>
</html>"""


@app.route("/")
def index():
    return render_template_string(HTML)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=DASHBOARD_PORT, debug=False)

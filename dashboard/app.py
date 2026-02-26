#!/usr/bin/env python3
"""YT SDI Streamer — Web Dashboard"""

import json
import os
import re
import subprocess
import time

# Fix for _www user having no accessible working directory
try:
    os.getcwd()
except (PermissionError, OSError):
    os.chdir("/tmp")

from flask import Flask, jsonify, render_template_string, request

# ---------- Configuration ----------
METRICS_PATH = "/var/log/yt-sdi-streamer/metrics.json"
STATUS_PATH = "/var/log/yt-sdi-streamer/status.json"
EVENTS_PATH = "/var/log/yt-sdi-streamer/events.jsonl"
YTCTL_PATH = "/usr/local/bin/ytctl"
HELPER_PATH = "/usr/local/bin/yt_dashboard_helper.sh"
DASHBOARD_PORT = 8080

QUALITY_PRESETS = {
    "low":      {"label": "Low",      "bitrate": "2500k", "description": "Bandwidth friendly"},
    "standard": {"label": "Standard", "bitrate": "4000k", "description": "Recommended default"},
    "high":     {"label": "High",     "bitrate": "8000k", "description": "High quality"},
}

INSTALL_STATIC = "/usr/local/lib/yt-dashboard/static"
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
LOCAL_STATIC = os.path.join(SCRIPT_DIR, "static")
STATIC_DIR = INSTALL_STATIC if os.path.isdir(INSTALL_STATIC) else LOCAL_STATIC

app = Flask(__name__, static_folder=STATIC_DIR)

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


LAUNCHD_LABEL = "com.kalaignar.yt-sdi-streamer"
SERVICE_CACHE_TTL = 5  # seconds

_service_cache = {"running": False, "checked_at": 0.0}

def is_service_running():
    """Check if the streamer LaunchDaemon is loaded and running (cached for 5s)."""
    now = time.monotonic()
    if now - _service_cache["checked_at"] < SERVICE_CACHE_TTL:
        return _service_cache["running"]
    try:
        result = subprocess.run(
            ["sudo", "launchctl", "print", f"system/{LAUNCHD_LABEL}"],
            capture_output=True, text=True, timeout=5
        )
        running = result.returncode == 0
    except Exception:
        running = False
    _service_cache["running"] = running
    _service_cache["checked_at"] = now
    return running


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
    ok, output = run_sudo([HELPER_PATH, "write-bitrate", bitrate])
    if not ok:
        return jsonify({"error": output}), 500
    return jsonify({"ok": True, "message": "Bitrate updated. Restart the service for it to take effect."})


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


@app.route("/api/control", methods=["POST"])
def api_control():
    data = request.get_json(silent=True)
    if not data or "action" not in data:
        return jsonify({"error": "Missing 'action' in request body"}), 400
    action = data["action"]
    if action not in ("start", "stop", "restart"):
        return jsonify({"error": "Invalid action. Use start, stop, or restart."}), 400
    ok, output = run_sudo([YTCTL_PATH, action])
    if not ok:
        return jsonify({"ok": False, "error": output}), 500
    return jsonify({"ok": True, "output": output})


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

  <!-- Header -->
  <header class="header">
    <div class="header-left">
      <div class="logo-icon">AB</div>
      <h1>ASHMAN Broadcast</h1>
    </div>
    <div class="header-right">
      <div class="conn-indicator">
        <span class="conn-dot err" id="conn"></span>
        <span id="connLabel">Connecting...</span>
      </div>
      <span class="mode-badge mode-unknown" id="modeBadge">---</span>
    </div>
  </header>

  <div class="container">

    <!-- Controls -->
    <div class="glass control-bar">
      <div class="control-status">
        <span class="control-dot" id="controlDot"></span>
        <span class="control-label" id="serviceStatusText">Connecting...</span>
      </div>
      <div class="control-actions">
        <button class="btn btn-start" id="btn-start" disabled onclick="ctrlAction('start')">Start</button>
        <button class="btn btn-stop" id="btn-stop" disabled onclick="ctrlAction('stop')">Stop</button>
        <button class="btn btn-restart" id="btn-restart" disabled onclick="ctrlAction('restart')">Restart</button>
      </div>
    </div>

    <!-- Settings -->
    <div class="settings-section">
      <div class="settings-tabs">
        <button class="settings-tab active" id="tab-presets" onclick="switchSettingsTab('presets')">Quality Presets</button>
        <button class="settings-tab" id="tab-configure" onclick="switchSettingsTab('configure')">Configure</button>
      </div>

      <!-- Presets Panel -->
      <div class="settings-panel active" id="panel-presets">
        <div class="presets-grid" id="presetsGrid">
          <div class="no-data">Loading presets...</div>
        </div>
        <div class="preset-status" id="presetStatus"></div>
      </div>

      <!-- Configure Panel -->
      <div class="settings-panel" id="panel-configure">
        <div class="glass configure-card">
          <div class="cfg-row">
            <div class="cfg-label">Video Bitrate</div>
            <div class="cfg-value"><span class="key-display" id="bitrateDisplay">Loading...</span></div>
            <div class="cfg-input">
              <input class="key-input" id="bitrateInput" placeholder="e.g. 4000k, 8000k" autocomplete="off" spellcheck="false">
              <button class="btn-sm btn-save" id="btnSaveBitrate" disabled onclick="saveBitrate()">Save</button>
            </div>
          </div>
          <div class="cfg-divider"></div>
          <div class="cfg-row">
            <div class="cfg-label">Playback URL</div>
            <div class="cfg-value"><span class="key-display" id="playbackUrlDisplay">Loading...</span></div>
            <div class="cfg-input">
              <input class="key-input" id="playbackUrlInput" placeholder="https://youtu.be/..." autocomplete="off" spellcheck="false">
              <button class="btn-sm btn-save" id="btnSavePlaybackUrl" disabled onclick="savePlaybackUrl()">Save</button>
            </div>
          </div>
          <div class="cfg-divider"></div>
          <div class="cfg-row">
            <div class="cfg-label">Stream Key</div>
            <div class="cfg-value">
              <span class="key-display" id="keyDisplay">Loading...</span>
              <button class="btn-sm btn-reveal" id="btnReveal" onclick="toggleReveal()">Reveal</button>
            </div>
            <div class="cfg-input">
              <input class="key-input" id="keyInput" placeholder="Enter new stream key..." autocomplete="off" spellcheck="false">
              <button class="btn-sm btn-save" id="btnSaveKey" disabled onclick="saveKey()">Save</button>
            </div>
          </div>
          <div class="cfg-hint">Changes require a broadcast restart to take effect.</div>
        </div>
      </div>
    </div>

    <!-- Metrics -->
    <div class="metrics-grid">

      <!-- Broadcast Status -->
      <div class="glass metric-card">
        <div class="card-header">
          <h3>Broadcast Status</h3>
          <div class="card-icon icon-status">&#9881;</div>
        </div>
        <div class="stat-featured">
          <div class="big-value" id="s-uptime">--:--:--</div>
          <div class="big-label">Uptime</div>
        </div>
        <div class="stat-row"><span class="stat-label">Mode</span><span class="stat-value" id="s-mode">-</span></div>
        <div class="stat-row"><span class="stat-label">State</span><span class="stat-value" id="s-state">-</span></div>
        <div class="stat-row"><span class="stat-label">Bitrate (config)</span><span class="stat-value" id="s-bitrate">-</span></div>
        <div class="stat-row"><span class="stat-label">Enc Bitrate</span><span class="stat-value" id="s-enc-bitrate">-</span></div>
        <div class="stat-row"><span class="stat-label">FPS</span><span class="stat-value" id="s-fps">-</span></div>
        <div class="stat-row"><span class="stat-label">Speed</span><span class="stat-value" id="s-speed">-</span></div>
        <div class="stat-row"><span class="stat-label">Last Update</span><span class="stat-value" id="s-ts">-</span></div>
      </div>

      <!-- Network -->
      <div class="glass metric-card">
        <div class="card-header">
          <h3>Network</h3>
          <div class="card-icon icon-network">&#9729;</div>
        </div>
        <div class="stat-row"><span class="stat-label">Interface</span><span class="stat-value" id="n-iface">-</span></div>
        <div class="stat-row"><span class="stat-label">IP Address</span><span class="stat-value" id="n-ip">-</span></div>
        <div class="stat-row"><span class="stat-label">Gateway</span><span class="stat-value" id="n-gw">-</span></div>
        <div class="stat-row"><span class="stat-label">RX Rate</span><span class="stat-value" id="n-rx-rate">-</span></div>
        <div class="stat-row"><span class="stat-label">TX Rate</span><span class="stat-value" id="n-tx-rate">-</span></div>
        <div class="stat-row"><span class="stat-label">Packet Loss</span><span class="stat-value" id="n-loss">-</span></div>
        <div class="stat-row"><span class="stat-label">Latency</span><span class="stat-value" id="n-avg">-</span></div>
        <div class="stat-row"><span class="stat-label">Jitter</span><span class="stat-value" id="n-jitter">-</span></div>
      </div>

    </div>

    <!-- Events -->
    <div class="glass events-card">
      <div class="card-header">
        <h3>Recent Events</h3>
      </div>
      <div class="events-scroll">
        <table class="events-table">
          <thead><tr><th>Time</th><th>Level</th><th>Event</th><th>Message</th></tr></thead>
          <tbody id="eventsBody"><tr><td colspan="4" class="no-data">Loading events...</td></tr></tbody>
        </table>
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
        <button class="btn btn-stop" id="confirmBtn">Confirm</button>
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

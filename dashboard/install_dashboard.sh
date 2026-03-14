#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# install_dashboard.sh — Install the YT SDI Streamer web dashboard on macOS
###############################################################################

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.kalaignar.yt-dashboard"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
INSTALL_BIN="/usr/local/bin"
LOG_DIR="/var/log/yt-sdi-streamer"
SUDOERS_FILE="/etc/sudoers.d/yt-dashboard"

echo "=== YT SDI Streamer Dashboard Installer ==="
echo

# Must run as root
if [[ "$(id -u)" -ne 0 ]]; then
  echo "Error: This script must be run with sudo."
  echo "  sudo bash ${0}"
  exit 1
fi

# Find Python 3 — prefer real python3.12 over the macOS stub at /usr/bin/python3
PYTHON3=""
for candidate in /usr/local/bin/python3.12 /usr/local/bin/python3 /usr/bin/python3; do
  if "${candidate}" -c "import sys; sys.exit(0 if sys.version_info >= (3,8) else 1)" 2>/dev/null; then
    PYTHON3="${candidate}"
    break
  fi
done
if [[ -z "${PYTHON3}" ]]; then
  echo "Error: Python 3.8+ not found."
  echo "Install from: https://www.python.org/ftp/python/3.12.8/python-3.12.8-macos11.pkg"
  exit 1
fi
echo "[OK] Python 3 found: $(${PYTHON3} --version) at ${PYTHON3}"

# Install Flask
echo "[..] Checking for Flask..."
if "${PYTHON3}" -c "import flask" 2>/dev/null; then
  echo "[OK] Flask is already installed"
else
  echo "[..] Installing Flask..."
  "${PYTHON3}" -m pip install flask --break-system-packages 2>/dev/null \
    || "${PYTHON3}" -m pip install flask
  echo "[OK] Flask installed"
fi

# Create log directory
mkdir -p "${LOG_DIR}"
chmod 755 "${LOG_DIR}"
echo "[OK] Log directory: ${LOG_DIR}"

# Install app.py
cp "${SCRIPT_DIR}/app.py" "${INSTALL_BIN}/yt_dashboard.py"
chmod 755 "${INSTALL_BIN}/yt_dashboard.py"
echo "[OK] Installed ${INSTALL_BIN}/yt_dashboard.py"

# Install static files (CSS/JS)
STATIC_DEST="/usr/local/lib/yt-dashboard/static"
mkdir -p "${STATIC_DEST}"
cp "${SCRIPT_DIR}/static/style.css" "${STATIC_DEST}/style.css"
cp "${SCRIPT_DIR}/static/app.js" "${STATIC_DEST}/app.js"
chmod -R 755 /usr/local/lib/yt-dashboard
echo "[OK] Installed static files to ${STATIC_DEST}"

# Install helper script
cp "${SCRIPT_DIR}/yt_dashboard_helper.sh" "${INSTALL_BIN}/yt_dashboard_helper.sh"
chmod 755 "${INSTALL_BIN}/yt_dashboard_helper.sh"
chown root:wheel "${INSTALL_BIN}/yt_dashboard_helper.sh"
echo "[OK] Installed ${INSTALL_BIN}/yt_dashboard_helper.sh"

# Install sudoers entry
cat > "${SUDOERS_FILE}" <<'SUDOERS'
# YT SDI Streamer Dashboard — allow unprivileged dashboard to control services
# ytctl multi-service commands
ALL ALL=(root) NOPASSWD: /usr/local/bin/ytctl *
# Dashboard helper
ALL ALL=(root) NOPASSWD: /usr/local/bin/yt_dashboard_helper.sh read-key
ALL ALL=(root) NOPASSWD: /usr/local/bin/yt_dashboard_helper.sh write-key *
ALL ALL=(root) NOPASSWD: /usr/local/bin/yt_dashboard_helper.sh read-bitrate
ALL ALL=(root) NOPASSWD: /usr/local/bin/yt_dashboard_helper.sh write-bitrate *
ALL ALL=(root) NOPASSWD: /usr/local/bin/yt_dashboard_helper.sh read-resolution
ALL ALL=(root) NOPASSWD: /usr/local/bin/yt_dashboard_helper.sh write-resolution *
ALL ALL=(root) NOPASSWD: /usr/local/bin/yt_dashboard_helper.sh read-playback-url
ALL ALL=(root) NOPASSWD: /usr/local/bin/yt_dashboard_helper.sh write-playback-url *
ALL ALL=(root) NOPASSWD: /usr/local/bin/yt_dashboard_helper.sh read-profiles
ALL ALL=(root) NOPASSWD: /usr/local/bin/yt_dashboard_helper.sh write-profile *
ALL ALL=(root) NOPASSWD: /usr/local/bin/yt_dashboard_helper.sh switch-profile *
ALL ALL=(root) NOPASSWD: /usr/local/bin/yt_dashboard_helper.sh read-dashboard-creds
# launchctl for all services
ALL ALL=(root) NOPASSWD: /usr/sbin/launchctl print system/com.kalaignar.yt-sdi-streamer
ALL ALL=(root) NOPASSWD: /usr/sbin/launchctl print system/com.kalaignar.yt-ingest
ALL ALL=(root) NOPASSWD: /usr/sbin/launchctl print system/com.kalaignar.yt-bridge
ALL ALL=(root) NOPASSWD: /usr/sbin/launchctl print system/com.kalaignar.mediamtx
ALL ALL=(root) NOPASSWD: /usr/sbin/launchctl print system/com.kalaignar.yt-dashboard
SUDOERS
chmod 440 "${SUDOERS_FILE}"
chown root:wheel "${SUDOERS_FILE}"

# Validate sudoers
if visudo -c -f "${SUDOERS_FILE}" &>/dev/null; then
  echo "[OK] Sudoers entry installed and validated"
else
  echo "[ERROR] Sudoers validation failed! Removing ${SUDOERS_FILE}"
  rm -f "${SUDOERS_FILE}"
  exit 1
fi

# Create default profiles file if missing
PROFILES_FILE="/etc/yt-sdi-streamer-profiles.json"
if [[ ! -f "${PROFILES_FILE}" ]]; then
  cat > "${PROFILES_FILE}" <<'PROFILES'
{
  "active": "standard",
  "profiles": {
    "low":      { "name": "Low",      "platform": "youtube", "stream_key": "", "bitrate": "2500k", "playback_url": "", "channel_id": "", "resolution": "1920x1080" },
    "standard": { "name": "Standard", "platform": "youtube", "stream_key": "", "bitrate": "4000k", "playback_url": "", "channel_id": "", "resolution": "1920x1080" },
    "high":     { "name": "High",     "platform": "youtube", "stream_key": "", "bitrate": "8000k", "playback_url": "", "channel_id": "", "resolution": "1920x1080" }
  }
}
PROFILES
  chmod 644 "${PROFILES_FILE}"
  echo "[OK] Created default profiles: ${PROFILES_FILE}"
else
  echo "[OK] Profiles file already exists: ${PROFILES_FILE}"
fi

# Add dashboard credentials to config if missing
CONF="/etc/yt-sdi-streamer.conf"
if [[ -f "${CONF}" ]]; then
  if ! grep -q '^DASHBOARD_USER=' "${CONF}"; then
    cat >> "${CONF}" <<'CREDS'

# --- Dashboard credentials ---
DASHBOARD_USER="ashman"
DASHBOARD_PASS="apple"
CREDS
    echo "[OK] Added dashboard credentials to ${CONF}"
  else
    echo "[OK] Dashboard credentials already in ${CONF}"
  fi
fi

# Make sure ytctl is installed
if [[ ! -f "${INSTALL_BIN}/ytctl" ]]; then
  echo "[WARN] ytctl not found at ${INSTALL_BIN}/ytctl — copying from source"
  cp "${SCRIPT_DIR}/../ytctl.sh" "${INSTALL_BIN}/ytctl"
  chmod 755 "${INSTALL_BIN}/ytctl"
fi

# Install and start LaunchDaemon
cp "${SCRIPT_DIR}/${LABEL}.plist" "${PLIST}"
chmod 644 "${PLIST}"
chown root:wheel "${PLIST}"

# Stop existing instance if running
launchctl bootout system "${PLIST}" 2>/dev/null || true
sleep 1

# Start
launchctl bootstrap system "${PLIST}"
launchctl enable system/"${LABEL}" 2>/dev/null || true
echo "[OK] LaunchDaemon installed and started"

echo
echo "=== Dashboard is running ==="
echo "  URL: http://$(hostname)"
echo "  Logs: ${LOG_DIR}/dashboard.out / dashboard.err"
echo
echo "To uninstall, run: sudo bash $(dirname "$0")/uninstall_dashboard.sh"

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

# Check Python 3
if ! command -v /usr/bin/python3 &>/dev/null; then
  echo "Error: Python 3 not found at /usr/bin/python3"
  echo "Install Xcode Command Line Tools: xcode-select --install"
  exit 1
fi
echo "[OK] Python 3 found: $(/usr/bin/python3 --version)"

# Install Flask
echo "[..] Checking for Flask..."
if /usr/bin/python3 -c "import flask" 2>/dev/null; then
  echo "[OK] Flask is already installed"
else
  echo "[..] Installing Flask..."
  /usr/bin/python3 -m pip install flask --break-system-packages 2>/dev/null \
    || /usr/bin/python3 -m pip install flask
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
# YT SDI Streamer Dashboard — allow unprivileged dashboard to control the service
ALL ALL=(root) NOPASSWD: /usr/local/bin/ytctl start
ALL ALL=(root) NOPASSWD: /usr/local/bin/ytctl stop
ALL ALL=(root) NOPASSWD: /usr/local/bin/ytctl restart
ALL ALL=(root) NOPASSWD: /usr/local/bin/ytctl status
ALL ALL=(root) NOPASSWD: /usr/local/bin/yt_dashboard_helper.sh read-key
ALL ALL=(root) NOPASSWD: /usr/local/bin/yt_dashboard_helper.sh write-key *
ALL ALL=(root) NOPASSWD: /usr/local/bin/yt_dashboard_helper.sh read-bitrate
ALL ALL=(root) NOPASSWD: /usr/local/bin/yt_dashboard_helper.sh write-bitrate *
ALL ALL=(root) NOPASSWD: /usr/local/bin/yt_dashboard_helper.sh read-playback-url
ALL ALL=(root) NOPASSWD: /usr/local/bin/yt_dashboard_helper.sh write-playback-url *
ALL ALL=(root) NOPASSWD: /usr/sbin/launchctl print system/com.kalaignar.yt-sdi-streamer
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
echo "  URL: http://$(hostname):8080"
echo "  Logs: ${LOG_DIR}/dashboard.out / dashboard.err"
echo
echo "To uninstall, run: sudo bash $(dirname "$0")/uninstall_dashboard.sh"

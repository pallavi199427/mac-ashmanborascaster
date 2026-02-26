#!/usr/bin/env bash
set -euo pipefail

APP_LABEL="com.kalaignar.yt-sdi-streamer"

# Source files (from this directory)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN_SRC="${HERE}/yt_sdi_streamer.sh"
CONF_SRC="${HERE}/yt-sdi-streamer.conf"
PLIST_SRC="${HERE}/com.kalaignar.yt-sdi-streamer.plist"
NEWSYSLOG_SRC="${HERE}/newsyslog.yt-sdi-streamer.conf"
ALERTS_SRC_DIR="${HERE}/alerts"
YTCTL_SRC="${HERE}/ytctl.sh"

# Destinations
BIN_DST="/usr/local/bin/yt_sdi_streamer.sh"
YTCTL_DST="/usr/local/bin/ytctl"
CONF_DST="/etc/yt-sdi-streamer.conf"
PLIST_DST="/Library/LaunchDaemons/${APP_LABEL}.plist"
NEWSYSLOG_DST="/etc/newsyslog.d/yt-sdi-streamer.conf"

LIB_DIR="/usr/local/lib/yt-sdi-streamer"
ALERTS_DST_DIR="${LIB_DIR}/alerts"

LOG_DIR="/var/log/yt-sdi-streamer"
STATE_DIR="/var/lib/yt-sdi-streamer"

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
fi

need() { [[ -e "$1" ]] || { echo "Missing: $1" >&2; exit 1; }; }

need "${BIN_SRC}"
need "${CONF_SRC}"
need "${PLIST_SRC}"
need "${NEWSYSLOG_SRC}"
need "${ALERTS_SRC_DIR}"
need "${YTCTL_SRC}"

echo "== Installing yt-sdi-streamer appliance =="
echo "This will require sudo."

sudo mkdir -p /usr/local/bin
sudo mkdir -p "${LOG_DIR}"
sudo mkdir -p "${LIB_DIR}"
sudo mkdir -p "${ALERTS_DST_DIR}"
sudo mkdir -p "${STATE_DIR}"

# Install main runner
sudo install -m 755 "${BIN_SRC}" "${BIN_DST}"
sudo install -m 755 "${YTCTL_SRC}" "${YTCTL_DST}"

# Install config (contains secret). Don't clobber by default.
if [[ -f "${CONF_DST}" && "${FORCE}" -ne 1 ]]; then
  echo "== Config exists at ${CONF_DST}; leaving it in place (use --force to overwrite) =="
else
  sudo install -m 600 "${CONF_SRC}" "${CONF_DST}"
fi

# Install alerts
sudo rsync -a "${ALERTS_SRC_DIR}/" "${ALERTS_DST_DIR}/"
sudo chmod -R 755 "${ALERTS_DST_DIR}"

# Install LaunchDaemon plist
sudo install -m 644 "${PLIST_SRC}" "${PLIST_DST}"
sudo chown root:wheel "${PLIST_DST}" "${BIN_DST}" || true
if [[ -f "${CONF_DST}" ]]; then
  sudo chown root:wheel "${CONF_DST}" || true
fi

# Install newsyslog rotation config
sudo mkdir -p /etc/newsyslog.d
sudo install -m 644 "${NEWSYSLOG_SRC}" "${NEWSYSLOG_DST}"

# Ensure log dir perms
sudo chmod 755 "${LOG_DIR}"

if [[ ! -f "${STATE_DIR}/logo.png" ]]; then
  echo "NOTE: Place your logo at ${STATE_DIR}/logo.png (PNG recommended)."
fi

# Unload if already loaded
sudo launchctl bootout system "${PLIST_DST}" >/dev/null 2>&1 || true

# Load + enable
sudo launchctl bootstrap system "${PLIST_DST}"
sudo launchctl enable system/"${APP_LABEL}"

echo "== Installed =="
echo "Service label: ${APP_LABEL}"
echo "Logs: ${LOG_DIR}"
echo "Status: ${LOG_DIR}/status.json"
echo "Events: ${LOG_DIR}/events.jsonl"
echo
echo "To start immediately:"
echo "  sudo launchctl kickstart -k system/${APP_LABEL}"
echo
echo "To run manually (foreground):"
echo "  sudo ${BIN_DST}"

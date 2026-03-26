#!/usr/bin/env bash
set -euo pipefail

APP_LABEL="com.kalaignar.yt-sdi-streamer"
NETHARDEN_LABEL="com.kalaignar.yt-net-harden"

BIN_DST="/usr/local/bin/yt_sdi_streamer.sh"
NETHARDEN_DST="/usr/local/bin/yt_net_harden.sh"
YTCTL_DST="/usr/local/bin/ytctl"
CONF_DST="/etc/yt-sdi-streamer.conf"
PLIST_DST="/Library/LaunchDaemons/${APP_LABEL}.plist"
PLIST_NETHARDEN_DST="/Library/LaunchDaemons/${NETHARDEN_LABEL}.plist"
NEWSYSLOG_DST="/etc/newsyslog.d/yt-sdi-streamer.conf"

LIB_DIR="/usr/local/lib/yt-sdi-streamer"

echo "== Uninstalling yt-sdi-streamer appliance =="
echo "This will require sudo."

sudo launchctl bootout system "${PLIST_DST}" >/dev/null 2>&1 || true
sudo launchctl bootout system "${PLIST_NETHARDEN_DST}" >/dev/null 2>&1 || true

sudo rm -f "${PLIST_DST}" "${PLIST_NETHARDEN_DST}"
sudo rm -f "${BIN_DST}" "${NETHARDEN_DST}"
sudo rm -f "${YTCTL_DST}"
sudo rm -f "${NEWSYSLOG_DST}"

# Keep CONF by default to avoid destroying credentials unless user asks.
if [[ "${1:-}" == "--remove-config" ]]; then
  sudo rm -f "${CONF_DST}"
else
  echo "NOTE: Leaving config at ${CONF_DST}. Use --remove-config to delete it."
fi

sudo rm -rf "${LIB_DIR}"

echo "== Removed. Logs remain at /var/log/yt-sdi-streamer (delete if desired). =="
echo "== State remains at /var/lib/yt-sdi-streamer (logo etc.) =="

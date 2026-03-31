#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# uninstall_dashboard.sh — Remove the YT SDI Streamer web dashboard
###############################################################################

LABEL="com.kalaignar.yt-dashboard"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Error: This script must be run with sudo."
  exit 1
fi

echo "=== Uninstalling YT SDI Streamer Dashboard ==="

# Stop and remove LaunchDaemon
launchctl bootout system "${PLIST}" 2>/dev/null || true
rm -f "${PLIST}"
echo "[OK] LaunchDaemon removed"

# Remove installed files
rm -f /usr/local/bin/yt_dashboard.py
rm -f /usr/local/bin/yt_dashboard_helper.sh
rm -rf /usr/local/lib/yt-dashboard
echo "[OK] Binaries and static files removed"

# Remove sudoers entry
rm -f /etc/sudoers.d/yt-dashboard
echo "[OK] Sudoers entry removed"

# Remove dashboard logs (keep streamer logs)
rm -f /var/log/yt-sdi-streamer/dashboard.out
rm -f /var/log/yt-sdi-streamer/dashboard.err
echo "[OK] Dashboard logs removed"

echo
echo "Dashboard uninstalled successfully."

#!/usr/bin/env bash
set -euo pipefail

LABEL="com.kalaignar.yt-sdi-streamer"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
LOG_DIR="/var/log/yt-sdi-streamer"

cmd="${1:-help}"

case "${cmd}" in
  start)
    sudo launchctl bootstrap system "${PLIST}" >/dev/null 2>&1 || true
    sudo launchctl enable system/"${LABEL}" >/dev/null 2>&1 || true
    sudo launchctl kickstart -k system/"${LABEL}"
    echo "Started ${LABEL}"
    ;;
  stop)
    sudo launchctl bootout system "${PLIST}" >/dev/null 2>&1 || true
    echo "Stopped ${LABEL}"
    ;;
  restart)
    sudo launchctl bootout system "${PLIST}" >/dev/null 2>&1 || true
    sudo launchctl bootstrap system "${PLIST}"
    sudo launchctl enable system/"${LABEL}" >/dev/null 2>&1 || true
    sudo launchctl kickstart -k system/"${LABEL}"
    echo "Restarted ${LABEL}"
    ;;
  status)
    echo "Launchd service:"
    sudo launchctl print system/"${LABEL}" | head -n 80 || true
    echo
    echo "Current streamer status.json:"
    [[ -f "${LOG_DIR}/status.json" ]] && cat "${LOG_DIR}/status.json" || echo "No status.json yet"
    echo
    echo "Current streamer metrics.json:"
    [[ -f "${LOG_DIR}/metrics.json" ]] && cat "${LOG_DIR}/metrics.json" || echo "No metrics.json yet"
    ;;
  logs)
    tail -n 200 "${LOG_DIR}/events.jsonl" 2>/dev/null || true
    ;;
  follow)
    tail -f "${LOG_DIR}/events.jsonl"
    ;;
  ffmpeg)
    tail -f "${LOG_DIR}/ffmpeg.log"
    ;;
  *)
    cat <<USAGE
Usage: ${0##*/} {start|stop|restart|status|logs|follow|ffmpeg}
USAGE
    ;;
 esac

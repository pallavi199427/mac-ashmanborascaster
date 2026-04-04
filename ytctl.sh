#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# ytctl.sh — Multi-service control CLI for YT appliance
#
# Usage: ytctl [SERVICE] {start|stop|restart|status|logs|follow|ffmpeg}
#   SERVICE: ingest | bridge | mediamtx | uplink | dashboard | all (default: all)
#
# Compatible with macOS default bash 3.2 (no associative arrays).
###############################################################################

LOG_DIR="/var/log/yt-sdi-streamer"

# Service definitions — bash 3.x compatible (no declare -A)
get_label() {
  case "$1" in
    netharden) echo "com.kalaignar.yt-net-harden" ;;
    ingest)    echo "com.kalaignar.yt-ingest" ;;
    bridge)    echo "com.kalaignar.yt-bridge" ;;
    mediamtx)  echo "com.kalaignar.mediamtx" ;;
    uplink)    echo "com.kalaignar.yt-sdi-streamer" ;;
    dashboard) echo "com.kalaignar.yt-dashboard" ;;
    *) return 1 ;;
  esac
}

get_plist() {
  case "$1" in
    netharden) echo "/Library/LaunchDaemons/com.kalaignar.yt-net-harden.plist" ;;
    ingest)    echo "/Library/LaunchDaemons/com.kalaignar.yt-ingest.plist" ;;
    bridge)    echo "/Library/LaunchDaemons/com.kalaignar.yt-bridge.plist" ;;
    mediamtx)  echo "/Library/LaunchDaemons/com.kalaignar.mediamtx.plist" ;;
    uplink)    echo "/Library/LaunchDaemons/com.kalaignar.yt-sdi-streamer.plist" ;;
    dashboard) echo "/Library/LaunchDaemons/com.kalaignar.yt-dashboard.plist" ;;
    *) return 1 ;;
  esac
}

ALL_SERVICES="netharden ingest bridge mediamtx uplink dashboard"

# Start order: netharden first (one-shot), then ingest, mediamtx, bridge, uplink, dashboard
START_ORDER="netharden ingest mediamtx bridge uplink dashboard"
# Stop order: reverse
STOP_ORDER="dashboard uplink bridge mediamtx ingest netharden"

svc_start() {
  local svc="$1"
  local label; label="$(get_label "$svc")"
  local plist; plist="$(get_plist "$svc")"
  sudo launchctl bootstrap system "${plist}" >/dev/null 2>&1 || true
  sudo launchctl enable system/"${label}" >/dev/null 2>&1 || true
  sudo launchctl kickstart -k system/"${label}"
  echo "  Started ${svc} (${label})"
}

svc_stop() {
  local svc="$1"
  local label; label="$(get_label "$svc")"
  local plist; plist="$(get_plist "$svc")"
  sudo launchctl bootout system "${plist}" >/dev/null 2>&1 || true
  echo "  Stopped ${svc} (${label})"
}

svc_restart() {
  local svc="$1"
  svc_stop "${svc}"
  sleep 0.5
  svc_start "${svc}"
}

svc_status() {
  local svc="$1"
  local label; label="$(get_label "$svc")"
  if sudo launchctl print system/"${label}" >/dev/null 2>&1; then
    echo "  ${svc}: RUNNING"
  else
    echo "  ${svc}: STOPPED"
  fi
}

is_valid_service() {
  case "$1" in
    netharden|ingest|bridge|mediamtx|uplink|dashboard) return 0 ;;
    *) return 1 ;;
  esac
}

# Determine service and command from args
# Support both "ytctl start" (legacy) and "ytctl uplink start" (new)
service="all"
cmd="help"

if [[ $# -eq 1 ]]; then
  # Legacy mode: ytctl {start|stop|restart|status|logs|follow|ffmpeg|help}
  cmd="$1"
elif [[ $# -ge 2 ]]; then
  service="$1"
  cmd="$2"
fi

# Validate service
if [[ "${service}" != "all" ]] && ! is_valid_service "${service}"; then
  echo "Unknown service: ${service}"
  echo "Valid services: ingest bridge mediamtx uplink dashboard all"
  exit 1
fi

case "${cmd}" in
  start)
    echo "Starting services..."
    if [[ "${service}" == "all" ]]; then
      for svc in ${START_ORDER}; do
        svc_start "${svc}"
      done
    else
      svc_start "${service}"
    fi
    ;;
  stop)
    echo "Stopping services..."
    if [[ "${service}" == "all" ]]; then
      for svc in ${STOP_ORDER}; do
        svc_stop "${svc}"
      done
    else
      svc_stop "${service}"
    fi
    ;;
  restart)
    echo "Restarting services..."
    if [[ "${service}" == "all" ]]; then
      for svc in ${STOP_ORDER}; do
        svc_stop "${svc}"
      done
      sleep 1
      for svc in ${START_ORDER}; do
        svc_start "${svc}"
      done
    else
      svc_restart "${service}"
    fi
    ;;
  status)
    echo "Service status:"
    if [[ "${service}" == "all" ]]; then
      for svc in ${START_ORDER}; do
        svc_status "${svc}"
      done
      echo
      echo "Ingest status:"
      [[ -f "${LOG_DIR}/ingest_status.json" ]] && cat "${LOG_DIR}/ingest_status.json" || echo "  No ingest status yet"
      echo
      echo "Bridge status:"
      [[ -f "${LOG_DIR}/bridge_status.json" ]] && cat "${LOG_DIR}/bridge_status.json" || echo "  No bridge status yet"
      echo
      echo "Uplink status:"
      [[ -f "${LOG_DIR}/status.json" ]] && cat "${LOG_DIR}/status.json" || echo "  No uplink status yet"
      echo
      echo "Uplink metrics:"
      [[ -f "${LOG_DIR}/metrics.json" ]] && cat "${LOG_DIR}/metrics.json" || echo "  No uplink metrics yet"
    else
      svc_status "${service}"
    fi
    ;;
  logs)
    if [[ "${service}" == "ingest" ]]; then
      tail -n 200 "${LOG_DIR}/ingest_events.jsonl" 2>/dev/null || true
    else
      tail -n 200 "${LOG_DIR}/events.jsonl" 2>/dev/null || true
    fi
    ;;
  follow)
    if [[ "${service}" == "ingest" ]]; then
      tail -f "${LOG_DIR}/ingest_events.jsonl"
    else
      tail -f "${LOG_DIR}/events.jsonl"
    fi
    ;;
  ffmpeg)
    if [[ "${service}" == "ingest" ]]; then
      tail -f "${LOG_DIR}/ingest_ffmpeg.log"
    elif [[ "${service}" == "bridge" ]]; then
      tail -f "${LOG_DIR}/bridge_ffmpeg.log"
    else
      tail -f "${LOG_DIR}/ffmpeg.log"
    fi
    ;;
  *)
    cat <<USAGE
Usage: ${0##*/} [SERVICE] {start|stop|restart|status|logs|follow|ffmpeg}

Services: netharden  ingest  bridge  mediamtx  uplink  dashboard  all (default)

Examples:
  ${0##*/} start           # Start all services
  ${0##*/} uplink restart  # Restart uplink only
  ${0##*/} ingest status   # Check ingest status
  ${0##*/} ingest ffmpeg   # Follow ingest ffmpeg log
USAGE
    ;;
esac

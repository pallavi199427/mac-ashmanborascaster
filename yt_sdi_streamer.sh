#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# yt_sdi_streamer.sh — Uplink: Multicast → YouTube RTMP
#
# Reads the MPEG-TS multicast stream from the ingest process and sends it
# to YouTube via RTMP. By default remuxes (copy), optionally re-encodes
# when UPLINK_REENCODE=true.
#
# Features:
# - Remux or re-encode to RTMP
# - Bitrate ladder: MAX → SAFE after repeated failures
# - Output-stall watchdog (monitors ffmpeg -progress)
# - Auto restart with exponential backoff
# - Network hardening moved to yt_net_harden.sh (boot-time one-shot)
#
# Outputs:
# - /var/log/yt-sdi-streamer/events.jsonl
# - /var/log/yt-sdi-streamer/status.json
# - /var/log/yt-sdi-streamer/metrics.json
# - /var/log/yt-sdi-streamer/ffmpeg.log
###############################################################################

CONFIG_FILE="/etc/yt-sdi-streamer.conf"
[[ -f "${CONFIG_FILE}" ]] || { echo "Missing ${CONFIG_FILE}" >&2; exit 2; }

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

# ---------- Service identity ----------
SERVICE_NAME="yt-uplink"

# ---------- Paths ----------
LOG_DIR="${LOG_DIR:-/var/log/yt-sdi-streamer}"
EVENTS_LOG="${LOG_DIR}/events.jsonl"
FFMPEG_LOG="${LOG_DIR}/ffmpeg.log"
STATUS_JSON="${LOG_DIR}/status.json"
METRICS_JSON="${LOG_DIR}/metrics.json"
PID_FILE="${LOG_DIR}/streamer.pid"
PROGRESS_FILE="${LOG_DIR}/ffmpeg.progress"
SDI_SIGNAL_FILE="${LOG_DIR}/sdi_signal"

LIB_DIR="${LIB_DIR:-/usr/local/lib/yt-sdi-streamer}"
ALERTS_DIR="${ALERTS_DIR:-${LIB_DIR}/alerts}"
ALERT_SCRIPT="${ALERT_SCRIPT:-${ALERTS_DIR}/alert.sh}"

mkdir -p "${LOG_DIR}"
chmod 755 "${LOG_DIR}"

# ---------- Multicast input ----------
MULTICAST_IP="${MULTICAST_IP:-239.20.0.10}"
MULTICAST_PORT="${MULTICAST_PORT:-5000}"
MULTICAST_INPUT="udp://${MULTICAST_IP}:${MULTICAST_PORT}?fifo_size=1000000&overrun_nonfatal=1&buffer_size=2097152&timeout=5000000"

# ---------- Uplink mode ----------
UPLINK_REENCODE="${UPLINK_REENCODE:-false}"

# ---------- Singleton ----------
LOCK_FILE="/var/run/yt-sdi-streamer.lock"
LOCK_PGREP_PATTERN="yt_sdi_streamer.sh"

# ---------- Runtime state ----------
MODE="live"  # uplink is always "live" (no standby concept)
CURRENT_BITRATE=""
CURRENT_BUFSIZE=""
RTMP_ENDPOINT=""

START_EPOCH="$(date +%s)"
TOTAL_MODE_STARTS=0
TOTAL_FFMPEG_EXITS=0
LAST_EXIT_RC=0

CONSEC_FAILS=0
BACKOFF=0

# SDI probe not used by uplink, but set for common code compatibility
PROBE_OK_COUNT=0
PROBE_BAD_COUNT=0
SDI_SIGNAL_STATE=-1
OK_COUNT=0
BAD_COUNT=0

# Metrics cadence
METRICS_INTERVAL="${METRICS_INTERVAL:-1}"
NET_METRICS_INTERVAL="${NET_METRICS_INTERVAL:-10}"
ENABLE_NET_PING="${ENABLE_NET_PING:-false}"
PING_TARGET="${PING_TARGET:-8.8.8.8}"
PING_COUNT="${PING_COUNT:-3}"

# Output-stall watchdog
ENABLE_OUTPUT_STALL_WATCHDOG="${ENABLE_OUTPUT_STALL_WATCHDOG:-false}"
STALL_TIMEOUT_SECONDS="${STALL_TIMEOUT_SECONDS:-25}"
STALL_CHECK_INTERVAL="${STALL_CHECK_INTERVAL:-5}"

# Network metrics cache
NET_LAST_TS=0
NET_IFACE=""
NET_IP=""
NET_GW=""
NET_DNS=""
NET_RX_BYTES=0
NET_TX_BYTES=0
NET_PING_LOSS=""
NET_PING_AVG_MS=""
NET_PING_JITTER_MS=""

# ---------- Source shared library ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/yt_common.sh"

acquire_lock
install_cleanup_trap

# ---------- RTMP helper ----------
safe_endpoint() {
  echo "${YOUTUBE_RTMP_URL}/(redacted)"
}

# ---------- Network metrics (uplink-specific) ----------
discover_iface_for_service() {
  local info
  info="$(/usr/sbin/networksetup -getinfo "${NETWORK_SERVICE}" 2>/dev/null || true)"
  NET_IFACE="$(echo "${info}" | awk -F': ' '/Device:/{print $2; exit}' | tr -d '\r')" || true

  if [[ -z "${NET_IFACE}" ]]; then
    local ip
    ip="$(echo "${info}" | awk -F': ' '/^IP address:/{print $2; exit}' | tr -d '\r')" || true
    if [[ -n "${ip}" && "${ip}" != "none" ]]; then
      NET_IFACE="$(/sbin/ifconfig 2>/dev/null \
        | awk -v ip="${ip}" '/^[a-zA-Z]/{iface=$1} $0 ~ "inet " ip " "{gsub(/:$/,"",iface); print iface; exit}')" || true
    fi
  fi

  if [[ -z "${NET_IFACE}" ]]; then
    local mac
    mac="$(echo "${info}" | awk -F': ' '/^Ethernet Address:/{print $2; exit}' | tr -d '\r' | tr '[:upper:]' '[:lower:]')" || true
    if [[ -n "${mac}" && "${mac}" != "none" ]]; then
      NET_IFACE="$(/sbin/ifconfig 2>/dev/null \
        | awk -v mac="${mac}" '/^[a-zA-Z]/{iface=$1} tolower($0) ~ "ether " mac{gsub(/:$/,"",iface); print iface; exit}')" || true
    fi
  fi

  if [[ -z "${NET_IFACE}" ]]; then
    local svc_id
    svc_id="$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null \
      | awk -v svc="${NETWORK_SERVICE}" '/^Hardware Port:/{found=($0 ~ svc)} found && /^Device:/{print $2; exit}')" || true
    if [[ -n "${svc_id}" ]]; then
      NET_IFACE="${svc_id}"
    fi
  fi

  if [[ -z "${NET_IFACE}" ]]; then
    NET_IFACE="unknown"
  fi
  return 0
}

collect_dns() {
  local dns
  dns="$(/usr/sbin/scutil --dns 2>/dev/null | awk '/nameserver\[[0-9]+\]/{print $3}' | head -n 4 | paste -sd "," -)"
  [[ -z "${dns}" ]] && dns="unknown"
  NET_DNS="${dns}"
}

collect_gateway() {
  local gw
  gw="$(/sbin/route -n get default 2>/dev/null | awk '/gateway:/{print $2}' | head -n1)"
  [[ -z "${gw}" ]] && gw="unknown"
  NET_GW="${gw}"
}

collect_ip() {
  if [[ "${NET_IFACE}" != "unknown" && -n "${NET_IFACE}" ]]; then
    local ip
    ip="$(/usr/sbin/ipconfig getifaddr "${NET_IFACE}" 2>/dev/null || true)"
    [[ -z "${ip}" ]] && ip="unknown"
    NET_IP="${ip}"
  else
    NET_IP="unknown"
  fi
}

collect_rx_tx_bytes() {
  NET_RX_BYTES=0
  NET_TX_BYTES=0

  [[ -n "${NET_IFACE}" && "${NET_IFACE}" != "unknown" ]] || return 0

  local header line
  header="$(/usr/sbin/netstat -ib 2>/dev/null | head -n 1)"
  line="$(/usr/sbin/netstat -ib 2>/dev/null | awk -v IF="${NET_IFACE}" '$1==IF {l=$0} END{print l}')"
  [[ -n "${header}" && -n "${line}" ]] || return 0

  # shellcheck disable=SC2206
  local h=( $header )
  # shellcheck disable=SC2206
  local v=( $line )

  local i idxI=-1 idxO=-1
  for i in "${!h[@]}"; do
    [[ "${h[$i]}" == "Ibytes" ]] && idxI=$i
    [[ "${h[$i]}" == "Obytes" ]] && idxO=$i
  done

  if [[ $idxI -ge 0 && $idxO -ge 0 ]]; then
    NET_RX_BYTES="${v[$idxI]:-0}"
    NET_TX_BYTES="${v[$idxO]:-0}"
  fi
}

collect_ping_metrics() {
  NET_PING_LOSS=""
  NET_PING_AVG_MS=""
  NET_PING_JITTER_MS=""

  [[ "${ENABLE_NET_PING}" == "true" ]] || return 0

  local out
  out="$(/sbin/ping -n -q -c "${PING_COUNT}" "${PING_TARGET}" 2>/dev/null || true)"

  local loss
  loss="$(echo "${out}" | awk -F',' '/packet loss/{gsub(/^[ \t]+|[ \t]+$/,"",$3); print $3}' | sed 's/ packet loss//')"
  [[ -z "${loss}" ]] && loss="unknown"
  NET_PING_LOSS="${loss}"

  local rtt
  rtt="$(echo "${out}" | awk -F' = ' '/round-trip/{print $2}' | sed 's/ ms//')"
  if [[ -n "${rtt}" ]]; then
    NET_PING_AVG_MS="$(echo "${rtt}" | awk -F'/' '{print $2}')"
    NET_PING_JITTER_MS="$(echo "${rtt}" | awk -F'/' '{print $4}')"
    [[ -z "${NET_PING_AVG_MS}" ]] && NET_PING_AVG_MS="unknown"
    [[ -z "${NET_PING_JITTER_MS}" ]] && NET_PING_JITTER_MS="unknown"
  else
    NET_PING_AVG_MS="unknown"
    NET_PING_JITTER_MS="unknown"
  fi
  return 0
}

refresh_network_metrics_if_due() {
  local now due
  now="$(date +%s)"
  due=$(( NET_LAST_TS + NET_METRICS_INTERVAL ))

  if [[ "${NET_LAST_TS}" -eq 0 || "${now}" -ge "${due}" ]]; then
    NET_LAST_TS="${now}"

    if [[ -z "${NET_IFACE}" || "${NET_IFACE}" == "unknown" ]]; then
      discover_iface_for_service || true
    fi

    collect_ip
    collect_gateway
    collect_dns
    collect_rx_tx_bytes
    collect_ping_metrics
  fi
}

# ---------- Uplink-specific metrics ----------
write_metrics_snapshot() {
  local state="$1"; shift
  local ff_detail="${1:-{}}"

  local t now uptime
  t="$(ts_utc)"
  now="$(date +%s)"
  uptime=$(( now - START_EPOCH ))

  refresh_network_metrics_if_due

  local ping_obj
  if [[ "${ENABLE_NET_PING}" == "true" ]]; then
    ping_obj="{\"target\":\"$(json_escape "${PING_TARGET}")\",\"loss\":\"$(json_escape "${NET_PING_LOSS}")\",\"avg_ms\":\"$(json_escape "${NET_PING_AVG_MS}")\",\"jitter_ms\":\"$(json_escape "${NET_PING_JITTER_MS}")\"}"
  else
    ping_obj="null"
  fi

  local net_obj
  net_obj="{\"service\":\"$(json_escape "${NETWORK_SERVICE:-unknown}")\",\"iface\":\"$(json_escape "${NET_IFACE:-unknown}")\",\"ip\":\"$(json_escape "${NET_IP:-unknown}")\",\"gateway\":\"$(json_escape "${NET_GW:-unknown}")\",\"dns\":\"$(json_escape "${NET_DNS:-unknown}")\",\"rx_bytes\":${NET_RX_BYTES},\"tx_bytes\":${NET_TX_BYTES},\"ping\":${ping_obj}}"

  local sdi_sig
  sdi_sig="$(cat "${SDI_SIGNAL_FILE}" 2>/dev/null || echo "-1")"
  sdi_sig="${sdi_sig//[^0-9-]/}"
  [[ -z "${sdi_sig}" ]] && sdi_sig="-1"

  atomic_write "${METRICS_JSON}" <<EOF
{"ts":"${t}","uptime_s":${uptime},"mode":"$(json_escape "${MODE}")","state":"$(json_escape "${state}")","sdi_signal":${sdi_sig},"bitrate":"$(json_escape "${CURRENT_BITRATE}")","ffmpeg":${ff_detail},"switching":{"ok_count":${OK_COUNT},"bad_count":${BAD_COUNT},"probe_ok":${PROBE_OK_COUNT},"probe_bad":${PROBE_BAD_COUNT}},"restarts":{"consecutive_failures":${CONSEC_FAILS},"backoff_s":${BACKOFF},"total_mode_starts":${TOTAL_MODE_STARTS},"total_ffmpeg_exits":${TOTAL_FFMPEG_EXITS},"last_exit_rc":${LAST_EXIT_RC}},"network":${net_obj}}
EOF
}

# ---------- FFmpeg commands ----------
# Override kill_running_ffmpeg for uplink (kills multicast-reading ffmpeg)
kill_running_ffmpeg() {
  /usr/bin/pkill -TERM -f "${FFMPEG_BIN}.*-f flv" >/dev/null 2>&1 || true
  sleep 0.5
  /usr/bin/pkill -KILL -f "${FFMPEG_BIN}.*-f flv" >/dev/null 2>&1 || true
  sleep 1
}

build_ffmpeg_uplink_cmd() {
  if [[ "${UPLINK_REENCODE}" == "true" ]]; then
    # Re-encode mode: decode multicast, re-encode to RTMP
    local vf
    vf="$(build_live_vf)"
    cat <<EOF
"${FFMPEG_BIN}" -hide_banner -loglevel info \\
  -fflags +discardcorrupt+nobuffer \\
  -flags low_delay \\
  -err_detect ignore_err \\
  -analyzeduration 2000000 -probesize 5000000 \\
  -f mpegts \\
  -i "${MULTICAST_INPUT}" \\
  -vf "${vf}" \\
  -af "aresample=async=1:first_pts=0:min_hard_comp=0.100" \\
  -c:v h264_videotoolbox -profile:v high -level 4.2 \\
  -b:v ${CURRENT_BITRATE} -maxrate ${CURRENT_BITRATE} -bufsize ${CURRENT_BUFSIZE} \\
  -g ${GOP} -keyint_min ${KEYINT_MIN} \\
  -pix_fmt yuv420p \\
  $(audio_args) \\
  -stats_period 1 -progress "${PROGRESS_FILE}" \\
  -flvflags no_duration_filesize \\
  -rw_timeout 15000000 \\
  -f flv "${RTMP_ENDPOINT}"
EOF
  else
    # Remux mode: copy video, re-encode audio to fix timestamp discontinuities
    # from multicast UDP jitter/packet loss (prevents crackling on YouTube)
    cat <<EOF
"${FFMPEG_BIN}" -hide_banner -loglevel info \\
  -fflags +discardcorrupt+nobuffer \\
  -flags low_delay \\
  -err_detect ignore_err \\
  -analyzeduration 2000000 -probesize 5000000 \\
  -f mpegts \\
  -i "${MULTICAST_INPUT}" \\
  -c:v copy \\
  -af "aresample=async=1:first_pts=0:min_hard_comp=0.100" \\
  $(audio_args) \\
  -stats_period 1 -progress "${PROGRESS_FILE}" \\
  -flvflags no_duration_filesize \\
  -rw_timeout 15000000 \\
  -f flv "${RTMP_ENDPOINT}"
EOF
  fi
}

# ---------- Bitrate ladder callbacks ----------
on_ffmpeg_success() {
  CURRENT_BITRATE="${BITRATE_MAX_K}"
  CURRENT_BUFSIZE="${BUFSIZE_MAX_K}"
}

on_ffmpeg_failure() {
  if [[ "${UPLINK_REENCODE}" == "true" ]]; then
    if [[ "${CONSEC_FAILS}" -ge "${DOWNGRADE_AFTER_CONSECUTIVE_FAILURES}" ]]; then
      if [[ "${CURRENT_BITRATE}" != "${BITRATE_SAFE_K}" ]]; then
        log_event "WARN" "bitrate_downgrade" "Downgrading bitrate for stability" "\"from\":\"${CURRENT_BITRATE}\",\"to\":\"${BITRATE_SAFE_K}\""
        run_alert "bitrate_downgrade" "{\"from\":\"${CURRENT_BITRATE}\",\"to\":\"${BITRATE_SAFE_K}\"}"
        CURRENT_BITRATE="${BITRATE_SAFE_K}"
        CURRENT_BUFSIZE="${BUFSIZE_SAFE_K}"
      fi
    fi
  fi
}

# ---------- Quick DNS check (network hardening moved to yt_net_harden.sh) ----------
check_dns_fast() {
  if ! dscacheutil -q host -a name "a.rtmp.youtube.com" 2>/dev/null | grep -q "ip_address"; then
    log_event "WARN" "dns_not_ready" "DNS for a.rtmp.youtube.com not yet resolved; proceeding anyway"
  fi
}

# ---------- Preflight ----------
preflight() {
  require_bin "${FFMPEG_BIN}"
  require_bin /usr/sbin/networksetup
  require_bin /usr/sbin/scutil
  require_bin /usr/sbin/ipconfig
  require_bin /usr/sbin/netstat
  require_bin /sbin/route
  require_bin /usr/bin/pkill
  require_bin /usr/bin/pmset
  require_bin /usr/bin/dscacheutil
  require_bin /usr/bin/killall

  if [[ -z "${STREAM_KEY:-}" || "${STREAM_KEY}" == "YOUR_STREAM_KEY_HERE" || "${STREAM_KEY}" == "YOUR-STREAM-KEY-HERE" ]]; then
    log_event "ERROR" "config_stream_key_missing" "STREAM_KEY is not set in config"
    run_alert "config_stream_key_missing" "{}"
    exit 4
  fi

  RTMP_ENDPOINT="${YOUTUBE_RTMP_URL}/${STREAM_KEY}"
  CURRENT_BITRATE="${BITRATE_MAX_K}"
  CURRENT_BUFSIZE="${BUFSIZE_MAX_K}"

  echo $$ > "${PID_FILE}"
  echo "-1" > "${SDI_SIGNAL_FILE}"

  log_event "INFO" "boot" "yt-uplink starting" "\"reencode\":\"${UPLINK_REENCODE}\",\"multicast\":\"${MULTICAST_IP}:${MULTICAST_PORT}\""
  run_alert "boot" "{}"
  write_status "boot" "{}"

  discover_iface_for_service || true
  write_metrics_snapshot "boot" "{\"pid\":$$}"
}

# ---------- Uplink supervisor (no SDI probe, just restart loop) ----------
uplink_supervisor_loop() {
  CONSEC_FAILS=0
  BACKOFF="${RESTART_BACKOFF_SECONDS}"

  log_event "INFO" "supervisor_start" "Uplink supervisor loop started"
  run_alert "supervisor_start" "{}"
  write_status "supervising" "{\"mode\":\"uplink\"}"
  write_metrics_snapshot "supervising" "{}"

  while true; do
    set +e
    run_ffmpeg_mode "live" build_ffmpeg_uplink_cmd "false"
    local rc=$?
    set -e

    if [[ "${rc}" -eq 0 ]]; then
      log_event "WARN" "ffmpeg_exit_normal" "Uplink FFmpeg exited normally; restarting" "\"rc\":${rc}"
      run_alert "ffmpeg_exit_normal" "{\"rc\":${rc}}"
      CONSEC_FAILS=0
      BACKOFF="${RESTART_BACKOFF_SECONDS}"
      on_ffmpeg_success
      sleep 1
    else
      CONSEC_FAILS=$((CONSEC_FAILS+1))
      log_event "ERROR" "ffmpeg_exit_error" "Uplink FFmpeg exited with error" "\"rc\":${rc},\"consecutive_failures\":${CONSEC_FAILS}"
      run_alert "ffmpeg_exit_error" "{\"rc\":${rc},\"consecutive_failures\":${CONSEC_FAILS}}"

      on_ffmpeg_failure

      BACKOFF=$(( BACKOFF * 2 ))
      [[ "${BACKOFF}" -gt "${RESTART_BACKOFF_MAX_SECONDS}" ]] && BACKOFF="${RESTART_BACKOFF_MAX_SECONDS}"

      write_status "backoff" "{\"seconds\":${BACKOFF},\"mode\":\"uplink\",\"rc\":${rc}}"
      write_metrics_snapshot "backoff" "{\"seconds\":${BACKOFF},\"rc\":${rc}}"
      log_event "INFO" "restart_backoff" "Uplink restarting after backoff" "\"seconds\":${BACKOFF}"
      sleep "${BACKOFF}"
    fi

    sleep 2
  done
}

# ---------- Main ----------
main() {
  umask 022
  preflight
  check_dns_fast
  uplink_supervisor_loop
}

main "$@"

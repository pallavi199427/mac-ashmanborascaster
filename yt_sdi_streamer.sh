#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# yt_sdi_streamer.sh ??? Appliance-grade SDI -> YouTube streamer for macOS
#
# Core:
# - Live/Standby auto switching (standby slate w/ logo + clock)
# - Drift protection (aresample async)
# - Timestamp resilience (+genpts + wallclock timestamps)
# - Output-stall watchdog (monitors ffmpeg -progress)
# - Auto restart with exponential backoff
# - Bitrate ladder: MAX -> SAFE after repeated failures
# - Network hardening: service order, DNS, Wi-Fi off, sleep off, optional MTU
#
# Outputs:
# - /var/log/yt-sdi-streamer/events.jsonl
# - /var/log/yt-sdi-streamer/status.json
# - /var/log/yt-sdi-streamer/metrics.json
# - /var/log/yt-sdi-streamer/ffmpeg.log
###############################################################################

CONFIG_FILE="/etc/yt-sdi-streamer.conf"
#CONFIG_FILE="yt-sdi-streamer.conf"
[[ -f "${CONFIG_FILE}" ]] || { echo "Missing ${CONFIG_FILE}" >&2; exit 2; }

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

# ---------- Paths ----------
LOG_DIR="${LOG_DIR:-/var/log/yt-sdi-streamer}"
EVENTS_LOG="${LOG_DIR}/events.jsonl"
FFMPEG_LOG="${LOG_DIR}/ffmpeg.log"
STATUS_JSON="${LOG_DIR}/status.json"
METRICS_JSON="${LOG_DIR}/metrics.json"
PID_FILE="${LOG_DIR}/streamer.pid"
PROGRESS_FILE="${LOG_DIR}/ffmpeg.progress"

LIB_DIR="${LIB_DIR:-/usr/local/lib/yt-sdi-streamer}"
ALERTS_DIR="${ALERTS_DIR:-${LIB_DIR}/alerts}"
ALERT_SCRIPT="${ALERT_SCRIPT:-${ALERTS_DIR}/alert.sh}"

mkdir -p "${LOG_DIR}"
chmod 755 "${LOG_DIR}"

# ---------- Runtime state ----------
MODE="standby" # live|standby
CURRENT_BITRATE=""
CURRENT_BUFSIZE=""
RTMP_ENDPOINT=""

START_EPOCH="$(date +%s)"
TOTAL_MODE_STARTS=0
TOTAL_FFMPEG_EXITS=0
LAST_EXIT_RC=0

CONSEC_FAILS=0
BACKOFF=0

# SDI probe counters (for UX + tuning)
PROBE_OK_COUNT=0
PROBE_BAD_COUNT=0

# Hysteresis counters
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

# ---------- Helpers ----------
ts_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

json_escape() {
  local s="${1}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "${s}"
}

safe_endpoint() {
  # never log stream key
  echo "${YOUTUBE_RTMP_URL}/(redacted)"
}

atomic_write() {
  local path="$1"
  local tmp="${path}.tmp"
  cat > "${tmp}"
  mv "${tmp}" "${path}"
}

log_event() {
  local level="$1"; shift
  local event="$1"; shift
  local message="$1"; shift
  local extra="${1:-}"

  local t msg line
  t="$(ts_utc)"
  msg="$(json_escape "${message}")"

  line="{\"ts\":\"${t}\",\"level\":\"${level}\",\"event\":\"${event}\",\"message\":\"${msg}\",\"service\":\"yt-sdi-streamer\",\"mode\":\"$(json_escape "${MODE}")\",\"device\":\"$(json_escape "${DECKLINK_DEVICE}")\",\"format\":\"$(json_escape "${FORMAT_CODE}")\",\"bitrate\":\"$(json_escape "${CURRENT_BITRATE}")\",\"endpoint\":\"$(safe_endpoint)\""
  [[ -n "${extra}" ]] && line="${line},${extra}"
  line="${line}}"

  echo "${line}" >> "${EVENTS_LOG}"
}

write_status() {
  local state="$1"; shift
  local detail="${1:-{}}"
  local t
  t="$(ts_utc)"

  atomic_write "${STATUS_JSON}" <<EOF
{"ts":"${t}","state":"$(json_escape "${state}")","mode":"$(json_escape "${MODE}")","bitrate":"$(json_escape "${CURRENT_BITRATE}")","detail":${detail}}
EOF
}

run_alert() {
  local ev="$1"; shift
  local detail="${1:-{}}"

  if [[ -x "${ALERT_SCRIPT}" ]]; then
    # shellcheck disable=SC2034
    ALERT_TS="$(ts_utc)"
    ALERT_EVENT="${ev}"
    ALERT_MODE="${MODE}"
    ALERT_BITRATE="${CURRENT_BITRATE}"
    ALERT_DEVICE="${DECKLINK_DEVICE}"
    ALERT_FORMAT="${FORMAT_CODE}"
    ALERT_ENDPOINT="$(safe_endpoint)"
    ALERT_DETAIL="${detail}"

    ( "${ALERT_SCRIPT}" "${ev}" "${detail}" >> "${LOG_DIR}/alerts.log" 2>&1 ) || true
  fi
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    log_event "ERROR" "missing_binary" "Required binary not found: $1" "\"bin\":\"$(json_escape "$1")\""
    run_alert "missing_binary" "{\"bin\":\"$(json_escape "$1")\"}"
    exit 3
  }
}

# For commands that may require root.
SUDO=""
init_privs() {
  if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
    return 0
  fi

  # Non-interactive sudo only.
  if command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
    SUDO="sudo -n"
  else
    SUDO=""
  fi
}

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
    return $?
  fi

  if [[ -n "${SUDO}" ]]; then
    ${SUDO} "$@"
    return $?
  fi

  return 126
}

cleanup_logs_by_size() {
  local max_events_mb="${MAX_EVENTS_LOG_MB:-200}"
  local max_ffmpeg_mb="${MAX_FFMPEG_LOG_MB:-500}"

  if [[ -f "${EVENTS_LOG}" ]]; then
    local sz
    sz=$(du -m "${EVENTS_LOG}" | awk '{print $1}')
    if [[ "${sz}" -gt "${max_events_mb}" ]]; then
      tail -n 200000 "${EVENTS_LOG}" > "${EVENTS_LOG}.tmp" && mv "${EVENTS_LOG}.tmp" "${EVENTS_LOG}"
      log_event "WARN" "log_trim" "Trimmed events log (safety)" "\"max_mb\":${max_events_mb}"
    fi
  fi

  if [[ -f "${FFMPEG_LOG}" ]]; then
    local sz
    sz=$(du -m "${FFMPEG_LOG}" | awk '{print $1}')
    if [[ "${sz}" -gt "${max_ffmpeg_mb}" ]]; then
      tail -n 200000 "${FFMPEG_LOG}" > "${FFMPEG_LOG}.tmp" && mv "${FFMPEG_LOG}.tmp" "${FFMPEG_LOG}"
      log_event "WARN" "log_trim" "Trimmed ffmpeg log (safety)" "\"max_mb\":${max_ffmpeg_mb}"
    fi
  fi
}

# ---------- Network metrics ----------
discover_iface_for_service() {
  local info
  info="$(/usr/sbin/networksetup -getinfo "${NETWORK_SERVICE}" 2>/dev/null || true)"
  NET_IFACE="$(echo "${info}" | awk -F': ' '/Device:/{print $2; exit}' | tr -d '\r')" || true

  # Fallback 1: resolve via IP from networksetup → ifconfig
  if [[ -z "${NET_IFACE}" ]]; then
    local ip
    ip="$(echo "${info}" | awk -F': ' '/^IP address:/{print $2; exit}' | tr -d '\r')" || true
    if [[ -n "${ip}" && "${ip}" != "none" ]]; then
      NET_IFACE="$(/sbin/ifconfig 2>/dev/null \
        | awk -v ip="${ip}" '/^[a-zA-Z]/{iface=$1} $0 ~ "inet " ip " "{gsub(/:$/,"",iface); print iface; exit}')" || true
    fi
  fi

  # Fallback 2: resolve via Ethernet Address from networksetup → ifconfig
  if [[ -z "${NET_IFACE}" ]]; then
    local mac
    mac="$(echo "${info}" | awk -F': ' '/^Ethernet Address:/{print $2; exit}' | tr -d '\r' | tr '[:upper:]' '[:lower:]')" || true
    if [[ -n "${mac}" && "${mac}" != "none" ]]; then
      NET_IFACE="$(/sbin/ifconfig 2>/dev/null \
        | awk -v mac="${mac}" '/^[a-zA-Z]/{iface=$1} tolower($0) ~ "ether " mac{gsub(/:$/,"",iface); print iface; exit}')" || true
    fi
  fi

  # Fallback 3: use networksetup -listallhardwareports which always has Device line
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

write_metrics_snapshot() {
  # write_metrics_snapshot STATE FFMPEG_JSON_OBJECT
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

  atomic_write "${METRICS_JSON}" <<EOF
{"ts":"${t}","uptime_s":${uptime},"mode":"$(json_escape "${MODE}")","state":"$(json_escape "${state}")","bitrate":"$(json_escape "${CURRENT_BITRATE}")","ffmpeg":${ff_detail},"switching":{"ok_count":${OK_COUNT},"bad_count":${BAD_COUNT},"probe_ok":${PROBE_OK_COUNT},"probe_bad":${PROBE_BAD_COUNT}},"restarts":{"consecutive_failures":${CONSEC_FAILS},"backoff_s":${BACKOFF},"total_mode_starts":${TOTAL_MODE_STARTS},"total_ffmpeg_exits":${TOTAL_FFMPEG_EXITS},"last_exit_rc":${LAST_EXIT_RC}},"network":${net_obj}}
EOF
}

metrics_loop() {
  while true; do
    sleep "${METRICS_INTERVAL}"

    local out_time_ms frame fps speed enc_bitrate
    out_time_ms="$(awk -F= '$1=="out_time_ms" {v=$2} END{print v}' "${PROGRESS_FILE}" 2>/dev/null || true)"
    frame="$(awk -F= '$1=="frame" {v=$2} END{print v}' "${PROGRESS_FILE}" 2>/dev/null || true)"
    fps="$(awk -F= '$1=="fps" {v=$2} END{print v}' "${PROGRESS_FILE}" 2>/dev/null || true)"
    speed="$(awk -F= '$1=="speed" {v=$2} END{print v}' "${PROGRESS_FILE}" 2>/dev/null || true)"
    enc_bitrate="$(awk -F= '$1=="bitrate" {v=$2} END{print v}' "${PROGRESS_FILE}" 2>/dev/null || true)"

    [[ -z "${out_time_ms}" ]] && out_time_ms="0"
    [[ -z "${frame}" ]] && frame="0"
    [[ -z "${fps}" ]] && fps="0"
    [[ -z "${speed}" ]] && speed="0"
    [[ -z "${enc_bitrate}" ]] && enc_bitrate="0"

    local drop dup
    drop="$(tail -n 250 "${FFMPEG_LOG}" 2>/dev/null | grep -Eo 'drop=[0-9]+' | tail -n 1 | cut -d= -f2 || true)"
    dup="$(tail -n 250 "${FFMPEG_LOG}" 2>/dev/null | grep -Eo 'dup=[0-9]+' | tail -n 1 | cut -d= -f2 || true)"
    [[ -z "${drop}" ]] && drop="0"
    [[ -z "${dup}" ]] && dup="0"

    local pid
    pid="$(/usr/bin/pgrep -n -f "${FFMPEG_BIN}.*-progress ${PROGRESS_FILE}" 2>/dev/null || true)"
    [[ -z "${pid}" ]] && pid="0"

    local ff
    ff="{\"pid\":${pid},\"out_time_ms\":${out_time_ms},\"speed\":\"$(json_escape "${speed}")\",\"fps\":${fps},\"frame\":${frame},\"drop\":${drop},\"dup\":${dup},\"enc_bitrate\":\"$(json_escape "${enc_bitrate}")\"}"

    write_metrics_snapshot "running" "${ff}"
  done
}

watch_output_stall() {
  local last_ms="0"
  local last_change
  last_change="$(date +%s)"

  while true; do
    sleep "${STALL_CHECK_INTERVAL}"

    [[ -f "${PROGRESS_FILE}" ]] || continue

    local ms
    ms="$(awk -F= '$1=="out_time_ms" {v=$2} END{print v}' "${PROGRESS_FILE}" 2>/dev/null || true)"
    [[ -n "${ms}" ]] || continue

    if [[ "${ms}" != "${last_ms}" ]]; then
      last_ms="${ms}"
      last_change="$(date +%s)"
      continue
    fi

    local now stalled_for
    now="$(date +%s)"
    stalled_for=$(( now - last_change ))

    if [[ "${stalled_for}" -ge "${STALL_TIMEOUT_SECONDS}" ]]; then
      log_event "ERROR" "output_stalled" "Output progress stalled; restarting FFmpeg" "\"stalled_for\":${stalled_for},\"out_time_ms\":${last_ms}"
      run_alert "output_stalled" "{\"stalled_for\":${stalled_for},\"out_time_ms\":${last_ms}}"
      write_status "output_stalled" "{\"stalled_for\":${stalled_for},\"out_time_ms\":${last_ms}}"
      write_metrics_snapshot "output_stalled" "{\"out_time_ms\":${last_ms},\"stalled_for\":${stalled_for}}"
      kill_running_ffmpeg
      exit 0
    fi
  done
}

probe_sdi_signal() {
  local out

  out="$("${FFMPEG_BIN}" -hide_banner -loglevel info \
      -f decklink -video_input "${VIDEO_INPUT}" -audio_input "${AUDIO_INPUT}" \
      -i "${DECKLINK_DEVICE}" \
      -t 1 -f null - 2>&1 || true)"

  if echo "${out}" | grep -q "No input signal detected"; then
    return 1
  fi
  if echo "${out}" | grep -q "Input #0, decklink"; then
    return 0
  fi

  return 1
}

audio_args() {
  local codec="${AUDIO_CODEC:-aac}"

  if [[ "${codec}" == "libfdk_aac" ]]; then
    printf '%s' "-c:a libfdk_aac -ar ${AUDIO_RATE} -ac ${AUDIO_CHANNELS} -vbr ${FDK_VBR_MODE}"
    return 0
  fi

  local abr="${AUDIO_BITRATE_K:-160k}"
  printf '%s' "-c:a aac -b:a ${abr} -ar ${AUDIO_RATE} -ac ${AUDIO_CHANNELS}"
}

build_ffmpeg_live_cmd() {
  cat <<EOF
"${FFMPEG_BIN}" -hide_banner -loglevel info \\
  -thread_queue_size 8192 \\
  -fflags +genpts -use_wallclock_as_timestamps 1 \\
  -f decklink -video_input ${VIDEO_INPUT} -audio_input ${AUDIO_INPUT} \\
  -i "${DECKLINK_DEVICE}" \\
  -vf "${LIVE_VIDEO_FILTER}" \\
  -af "aresample=async=1:first_pts=0:min_hard_comp=0.100" \\
  -color_primaries ${COLOR_PRIMARIES} -color_trc ${COLOR_TRC} -colorspace ${COLOR_SPACE} -color_range tv \\
  -c:v h264_videotoolbox -profile:v high -level 4.2 \\
  -b:v ${CURRENT_BITRATE} -maxrate ${CURRENT_BITRATE} -bufsize ${CURRENT_BUFSIZE} \\
  -g ${GOP} -keyint_min ${KEYINT_MIN} \\
  -pix_fmt yuv420p \\
  $(audio_args) \\
  -stats_period 1 -progress "${PROGRESS_FILE}" \\
  -flvflags no_duration_filesize \\
  -f flv "${RTMP_ENDPOINT}"
EOF
}

build_ffmpeg_standby_cmd() {
  local logo_input=""
  local overlay_prefix=""

  if [[ "${LOGO_ENABLE}" == "true" && -n "${LOGO_PATH:-}" && -f "${LOGO_PATH}" ]]; then
    logo_input="-i \"${LOGO_PATH}\""
    overlay_prefix="[0:v][1:v]overlay=${LOGO_X}:${LOGO_Y},"
  fi

  cat <<EOF
TZ="${CLOCK_TZ}" "${FFMPEG_BIN}" -hide_banner -loglevel info \\
  -f lavfi -i "color=c=${STANDBY_BG_COLOR}:s=${STANDBY_SIZE}:r=${STANDBY_FPS}" \\
  ${logo_input} \\
  -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=${AUDIO_RATE}" \\
  -filter_complex "${overlay_prefix}drawtext=fontfile=${FONT_FILE}:text='${STANDBY_TITLE}':x=${TEXT_X}:y=${TEXT_Y}:fontsize=${TITLE_FONTSIZE}:fontcolor=white:box=1:boxcolor=black@0.35:boxborderw=18,drawtext=fontfile=${FONT_FILE}:text='%{localtime\\:%Y-%m-%d %H\\\\:%M\\\\:%S}':x=${TEXT_X}:y=${TEXT_Y}+${CLOCK_DY}:fontsize=${CLOCK_FONTSIZE}:fontcolor=white:box=1:boxcolor=black@0.25:boxborderw=14,drawtext=fontfile=${FONT_FILE}:text='${STANDBY_SUBTITLE}':x=${TEXT_X}:y=${TEXT_Y}+${SUBTITLE_DY}:fontsize=${SUBTITLE_FONTSIZE}:fontcolor=white@0.95" \\
  -map 0:v:0 -map 2:a:0 \\
  -c:v h264_videotoolbox -profile:v high -level 4.2 \\
  -b:v ${CURRENT_BITRATE} -maxrate ${CURRENT_BITRATE} -bufsize ${CURRENT_BUFSIZE} \\
  -g ${GOP} -keyint_min ${KEYINT_MIN} -pix_fmt yuv420p \\
  $(audio_args) \\
  -stats_period 1 -progress "${PROGRESS_FILE}" \\
  -flvflags no_duration_filesize \\
  -f flv "${RTMP_ENDPOINT}"
EOF
}

kill_running_ffmpeg() {
  /usr/bin/pkill -TERM -f "${FFMPEG_BIN}.*${DECKLINK_DEVICE}" >/dev/null 2>&1 || true
  /usr/bin/pkill -TERM -f "${FFMPEG_BIN}.*color=c=${STANDBY_BG_COLOR}" >/dev/null 2>&1 || true
  sleep 0.5
  /usr/bin/pkill -KILL -f "${FFMPEG_BIN}.*${DECKLINK_DEVICE}" >/dev/null 2>&1 || true
  /usr/bin/pkill -KILL -f "${FFMPEG_BIN}.*color=c=${STANDBY_BG_COLOR}" >/dev/null 2>&1 || true
}

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

  init_privs

  if [[ "${ENABLE_STANDBY}" == "true" ]]; then
    if [[ -n "${FONT_FILE:-}" && ! -f "${FONT_FILE}" ]]; then
      log_event "WARN" "standby_font_missing" "Standby FONT_FILE missing; drawtext may fail" "\"font\":\"$(json_escape "${FONT_FILE}")\""
      run_alert "standby_font_missing" "{\"font\":\"$(json_escape "${FONT_FILE}")\"}"
    fi
    if [[ "${LOGO_ENABLE}" == "true" && -n "${LOGO_PATH:-}" && ! -f "${LOGO_PATH}" ]]; then
      log_event "WARN" "standby_logo_missing" "Logo file missing; standby will run without logo" "\"logo\":\"$(json_escape "${LOGO_PATH}")\""
      run_alert "standby_logo_missing" "{\"logo\":\"$(json_escape "${LOGO_PATH}")\"}"
    fi
  fi

  if [[ -z "${STREAM_KEY:-}" || "${STREAM_KEY}" == "YOUR_STREAM_KEY_HERE" ]]; then
    log_event "ERROR" "config_stream_key_missing" "STREAM_KEY is not set in config"
    run_alert "config_stream_key_missing" "{}"
    exit 4
  fi

  RTMP_ENDPOINT="${YOUTUBE_RTMP_URL}/${STREAM_KEY}"
  echo $$ > "${PID_FILE}"

  log_event "INFO" "boot" "yt-sdi-streamer starting"
  run_alert "boot" "{}"
  write_status "boot" "{}"

  discover_iface_for_service || true
  write_metrics_snapshot "boot" "{\"pid\":$$}"
}

harden_network() {
  if [[ "${DO_NETWORK_HARDENING}" != "true" ]]; then
    log_event "INFO" "net_hardening_skip" "Network hardening disabled"
    return 0
  fi

  log_event "INFO" "net_hardening" "Starting network hardening"
  write_status "net_hardening" "{}"
  write_metrics_snapshot "net_hardening" "{}"

  if [[ "$(id -u)" -ne 0 && -z "${SUDO}" ]]; then
    log_event "WARN" "net_hardening" "Not running as root and sudo -n unavailable; skipping network hardening"
    write_status "idle" "{}"
    return 0
  fi

  if [[ "${ENFORCE_SERVICE_ORDER}" == "true" ]]; then
    local order=(/usr/sbin/networksetup -ordernetworkservices)
    local svc
    for svc in "${SERVICE_ORDER[@]}"; do
      order+=("${svc}")
    done
    run_root "${order[@]}" >/dev/null 2>&1 || log_event "WARN" "net_hardening" "Could not enforce network service order"
  fi

  if [[ "${SET_DNS}" == "true" ]]; then
    local dns=(/usr/sbin/networksetup -setdnsservers "${NETWORK_SERVICE}")
    local d
    for d in "${DNS_SERVERS[@]}"; do
      dns+=("${d}")
    done
    run_root "${dns[@]}" >/dev/null 2>&1 || log_event "WARN" "net_hardening" "Could not set DNS servers"

    run_root /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
    run_root /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true
  fi

  if [[ "${DISABLE_WIFI_DURING_RUN}" == "true" ]]; then
    run_root /usr/sbin/networksetup -setairportpower "Wi-Fi" off >/dev/null 2>&1 || log_event "WARN" "net_hardening" "Could not disable Wi-Fi"
  fi

  if [[ "${DISABLE_SLEEP}" == "true" ]]; then
    run_root /usr/bin/pmset -a sleep 0 disksleep 0 displaysleep 0 >/dev/null 2>&1 || log_event "WARN" "net_hardening" "Could not set pmset"
  fi

  if [[ -n "${MTU_VALUE}" ]]; then
    run_root /usr/sbin/networksetup -setMTU "${NETWORK_SERVICE}" "${MTU_VALUE}" >/dev/null 2>&1 || log_event "WARN" "net_hardening" "Could not set MTU"
  fi

  discover_iface_for_service || true

  log_event "INFO" "net_hardening" "Network hardening complete"
  write_status "idle" "{}"
  write_metrics_snapshot "idle" "{}"
}

run_ffmpeg_mode() {
  local mode="$1"
  MODE="${mode}"
  TOTAL_MODE_STARTS=$((TOTAL_MODE_STARTS+1))

  cleanup_logs_by_size

  log_event "INFO" "mode_start" "Starting mode ${mode}" "\"mode\":\"$(json_escape "${mode}")\""
  run_alert "mode_start" "{\"mode\":\"$(json_escape "${mode}")\",\"bitrate\":\"${CURRENT_BITRATE}\"}"
  write_status "${mode}_starting" "{\"mode\":\"$(json_escape "${mode}")\",\"bitrate\":\"${CURRENT_BITRATE}\"}"

  rm -f "${PROGRESS_FILE}" >/dev/null 2>&1 || true

  local stall_pid="" metrics_pid=""

  if [[ "${ENABLE_OUTPUT_STALL_WATCHDOG}" == "true" ]]; then
    watch_output_stall &
    stall_pid="$!"
    log_event "INFO" "stall_watchdog_start" "Started output stall watchdog" "\"pid\":${stall_pid}"
  fi

  metrics_loop &
  metrics_pid="$!"

  local rc
  local ffmpeg_pid=""
  local nosignal_file="${LOG_DIR}/nosignal.$$"
  local monitor_pid="" tail_pid=""

  # Ensure ffmpeg log exists before tail starts
  touch "${FFMPEG_LOG}"

  set +e
  if [[ "${mode}" == "live" ]]; then
    # Launch ffmpeg in background to get reliable PID + exit code
    bash -c "$(build_ffmpeg_live_cmd)" >> "${FFMPEG_LOG}" 2>&1 &
    ffmpeg_pid=$!

    # Tail ffmpeg log to stdout for visibility
    tail -n +1 -f "${FFMPEG_LOG}" &
    tail_pid=$!

    # Background monitor: watch for no-signal and update status
    rm -f "${nosignal_file}"
    (
      tail -n +1 -f "${FFMPEG_LOG}" 2>/dev/null | while IFS= read -r line; do
        local short
        short="$(echo "${line}" | tail -c 500 | tr -d '\r')"
        write_status "running" "{\"mode\":\"live\",\"bitrate\":\"${CURRENT_BITRATE}\",\"ffmpeg\":\"$(json_escape "${short}")\"}"

        if echo "${line}" | grep -q "No input signal detected"; then
          echo "1" >> "${nosignal_file}"
          local cnt
          cnt=$(wc -l < "${nosignal_file}" 2>/dev/null || echo 0)
          log_event "WARN" "no_signal" "SDI input signal missing" "\"count\":${cnt}"
          run_alert "no_signal" "{\"count\":${cnt}}"
          if [[ "${cnt}" -ge "${MAX_NO_SIGNAL_LINES}" ]]; then
            log_event "ERROR" "no_signal_restart" "Too many no-signal messages; restarting FFmpeg"
            run_alert "no_signal_restart" "{\"count\":${cnt}}"
            kill "${ffmpeg_pid}" 2>/dev/null || true
            break
          fi
        fi
      done
    ) &
    monitor_pid=$!

    # Wait for ffmpeg to finish ??? reliable exit code
    wait "${ffmpeg_pid}" 2>/dev/null
    rc=$?

    # Cleanup background processes
    kill "${tail_pid}" 2>/dev/null || true
    kill "${monitor_pid}" 2>/dev/null || true
    wait "${tail_pid}" 2>/dev/null || true
    wait "${monitor_pid}" 2>/dev/null || true
    rm -f "${nosignal_file}"

  else
    # STANDBY mode ??? same background PID pattern for reliable exit code
    bash -c "$(build_ffmpeg_standby_cmd)" >> "${FFMPEG_LOG}" 2>&1 &
    ffmpeg_pid=$!

    # Tail ffmpeg log to stdout for visibility
    tail -n +1 -f "${FFMPEG_LOG}" &
    tail_pid=$!

    # Background status updater
    (
      tail -n +1 -f "${FFMPEG_LOG}" 2>/dev/null | while IFS= read -r line; do
        local short
        short="$(echo "${line}" | tail -c 500 | tr -d '\r')"
        write_status "running" "{\"mode\":\"standby\",\"bitrate\":\"${CURRENT_BITRATE}\",\"ffmpeg\":\"$(json_escape "${short}")\"}"
      done
    ) &
    monitor_pid=$!

    # Wait for ffmpeg to finish ??? reliable exit code
    wait "${ffmpeg_pid}" 2>/dev/null
    rc=$?

    # Cleanup background processes
    kill "${tail_pid}" 2>/dev/null || true
    kill "${monitor_pid}" 2>/dev/null || true
    wait "${tail_pid}" 2>/dev/null || true
    wait "${monitor_pid}" 2>/dev/null || true
  fi
  set -e

  [[ -n "${metrics_pid}" ]] && kill "${metrics_pid}" >/dev/null 2>&1 || true
  [[ -n "${stall_pid}" ]] && kill "${stall_pid}" >/dev/null 2>&1 || true

  TOTAL_FFMPEG_EXITS=$((TOTAL_FFMPEG_EXITS+1))
  LAST_EXIT_RC="${rc}"
  write_metrics_snapshot "ffmpeg_exited" "{\"rc\":${rc}}"

  return "${rc}"
}

adjust_bitrate_on_failures() {
  if [[ "${CONSEC_FAILS}" -ge "${DOWNGRADE_AFTER_CONSECUTIVE_FAILURES}" ]]; then
    if [[ "${CURRENT_BITRATE}" != "${BITRATE_SAFE_K}" ]]; then
      log_event "WARN" "bitrate_downgrade" "Downgrading bitrate for stability" "\"from\":\"${CURRENT_BITRATE}\",\"to\":\"${BITRATE_SAFE_K}\""
      run_alert "bitrate_downgrade" "{\"from\":\"${CURRENT_BITRATE}\",\"to\":\"${BITRATE_SAFE_K}\"}"
      CURRENT_BITRATE="${BITRATE_SAFE_K}"
      CURRENT_BUFSIZE="${BUFSIZE_SAFE_K}"
    fi
  fi
}

supervisor_loop() {
  CURRENT_BITRATE="${BITRATE_MAX_K}"
  CURRENT_BUFSIZE="${BUFSIZE_MAX_K}"

  CONSEC_FAILS=0
  BACKOFF="${RESTART_BACKOFF_SECONDS}"
  OK_COUNT=0
  BAD_COUNT=0

  MODE="standby"

  log_event "INFO" "supervisor_start" "Supervisor loop started"
  run_alert "supervisor_start" "{}"
  write_status "supervising" "{\"mode\":\"${MODE}\"}"
  write_metrics_snapshot "supervising" "{}"

  while true; do
    if probe_sdi_signal; then
      PROBE_OK_COUNT=$((PROBE_OK_COUNT+1))
      OK_COUNT=$((OK_COUNT+1))
      BAD_COUNT=0
    else
      PROBE_BAD_COUNT=$((PROBE_BAD_COUNT+1))
      BAD_COUNT=$((BAD_COUNT+1))
      OK_COUNT=0
    fi

    if [[ "${ENABLE_STANDBY}" == "true" ]]; then
      if [[ "${MODE}" != "standby" && "${BAD_COUNT}" -ge "${SWITCH_TO_STANDBY_AFTER}" ]]; then
        log_event "WARN" "switch_to_standby" "Switching to standby (signal missing)" "\"bad\":${BAD_COUNT}"
        run_alert "switch_to_standby" "{\"bad\":${BAD_COUNT}}"
        kill_running_ffmpeg
        MODE="standby"
      fi

      if [[ "${MODE}" != "live" && "${OK_COUNT}" -ge "${SWITCH_TO_LIVE_AFTER}" ]]; then
        log_event "INFO" "switch_to_live" "Switching to live (signal present)" "\"ok\":${OK_COUNT}"
        run_alert "switch_to_live" "{\"ok\":${OK_COUNT}}"
        kill_running_ffmpeg
        MODE="live"
      fi
    else
      MODE="live"
    fi

    set +e
    run_ffmpeg_mode "${MODE}"
    local rc=$?
    set -e

    if [[ "${rc}" -eq 0 ]]; then
      log_event "WARN" "ffmpeg_exit_normal" "FFmpeg exited normally; restarting" "\"rc\":${rc}"
      run_alert "ffmpeg_exit_normal" "{\"rc\":${rc}}"
      CONSEC_FAILS=0
      BACKOFF="${RESTART_BACKOFF_SECONDS}"
      CURRENT_BITRATE="${BITRATE_MAX_K}"
      CURRENT_BUFSIZE="${BUFSIZE_MAX_K}"
      sleep 1
    else
      CONSEC_FAILS=$((CONSEC_FAILS+1))
      log_event "ERROR" "ffmpeg_exit_error" "FFmpeg exited with error" "\"rc\":${rc},\"consecutive_failures\":${CONSEC_FAILS}"
      run_alert "ffmpeg_exit_error" "{\"rc\":${rc},\"consecutive_failures\":${CONSEC_FAILS}}"

      adjust_bitrate_on_failures

      BACKOFF=$(( BACKOFF * 2 ))
      [[ "${BACKOFF}" -gt "${RESTART_BACKOFF_MAX_SECONDS}" ]] && BACKOFF="${RESTART_BACKOFF_MAX_SECONDS}"

      write_status "backoff" "{\"seconds\":${BACKOFF},\"mode\":\"${MODE}\",\"rc\":${rc}}"
      write_metrics_snapshot "backoff" "{\"seconds\":${BACKOFF},\"rc\":${rc}}"
      log_event "INFO" "restart_backoff" "Restarting after backoff" "\"seconds\":${BACKOFF}"
      sleep "${BACKOFF}"
    fi

    sleep "${PROBE_INTERVAL}"
  done
}

main() {
  umask 022
  preflight
  harden_network || true
  supervisor_loop
}

main "$@"

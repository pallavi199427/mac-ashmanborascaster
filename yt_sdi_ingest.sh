#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# yt_sdi_ingest.sh — SDI to UDP Multicast ingest for macOS
#
# Owns the DeckLink device exclusively. Encodes SDI input to H.264 via
# h264_videotoolbox and outputs MPEG-TS to a UDP multicast group.
#
# When no SDI signal is detected, outputs a standby slate (color bars +
# logo + clock) to the same multicast group so downstream consumers
# (bridge, uplink) always receive a stream.
#
# Outputs:
# - UDP multicast MPEG-TS stream
# - /var/log/yt-sdi-streamer/ingest_events.jsonl
# - /var/log/yt-sdi-streamer/ingest_status.json
# - /var/log/yt-sdi-streamer/ingest_metrics.json
# - /var/log/yt-sdi-streamer/ingest_ffmpeg.log
###############################################################################

CONFIG_FILE="/etc/yt-sdi-streamer.conf"
[[ -f "${CONFIG_FILE}" ]] || { echo "Missing ${CONFIG_FILE}" >&2; exit 2; }

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

# ---------- Service identity ----------
SERVICE_NAME="yt-ingest"

# ---------- Paths ----------
LOG_DIR="${LOG_DIR:-/var/log/yt-sdi-streamer}"
EVENTS_LOG="${LOG_DIR}/ingest_events.jsonl"
FFMPEG_LOG="${LOG_DIR}/ingest_ffmpeg.log"
STATUS_JSON="${LOG_DIR}/ingest_status.json"
METRICS_JSON="${LOG_DIR}/ingest_metrics.json"
PROGRESS_FILE="${LOG_DIR}/ingest_ffmpeg.progress"
SDI_SIGNAL_FILE="${LOG_DIR}/sdi_signal"

LIB_DIR="${LIB_DIR:-/usr/local/lib/yt-sdi-streamer}"
ALERTS_DIR="${ALERTS_DIR:-${LIB_DIR}/alerts}"
ALERT_SCRIPT="${ALERT_SCRIPT:-${ALERTS_DIR}/alert.sh}"

mkdir -p "${LOG_DIR}"
chmod 755 "${LOG_DIR}"

# ---------- Multicast config ----------
MULTICAST_IP="${MULTICAST_IP:-239.20.0.10}"
MULTICAST_PORT="${MULTICAST_PORT:-5000}"
MULTICAST_TTL="${MULTICAST_TTL:-1}"
MULTICAST_PKT_SIZE="${MULTICAST_PKT_SIZE:-1316}"
MULTICAST_OUTPUT="udp://${MULTICAST_IP}:${MULTICAST_PORT}?pkt_size=${MULTICAST_PKT_SIZE}&ttl=${MULTICAST_TTL}"

# ---------- Singleton ----------
LOCK_FILE="/var/run/yt-sdi-ingest.lock"
LOCK_PGREP_PATTERN="yt_sdi_ingest.sh"

# ---------- Runtime state ----------
MODE="standby"  # live|standby
CURRENT_BITRATE=""
START_EPOCH="$(date +%s)"
TOTAL_MODE_STARTS=0
TOTAL_FFMPEG_EXITS=0
LAST_EXIT_RC=0

CONSEC_FAILS=0
BACKOFF=0

PROBE_OK_COUNT=0
PROBE_BAD_COUNT=0
SDI_SIGNAL_STATE=-1

OK_COUNT=0
BAD_COUNT=0

METRICS_INTERVAL="${METRICS_INTERVAL:-1}"

# ---------- Source shared library ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/yt_common.sh"

acquire_lock
install_cleanup_trap

# ---------- Ingest-specific metrics ----------
write_metrics_snapshot() {
  local state="$1"; shift
  local ff_detail="${1:-{}}"

  local t now uptime
  t="$(ts_utc)"
  now="$(date +%s)"
  uptime=$(( now - START_EPOCH ))

  local sdi_sig
  sdi_sig="$(cat "${SDI_SIGNAL_FILE}" 2>/dev/null || echo "-1")"
  sdi_sig="${sdi_sig//[^0-9-]/}"
  [[ -z "${sdi_sig}" ]] && sdi_sig="-1"

  atomic_write "${METRICS_JSON}" <<EOF
{"ts":"${t}","service":"yt-ingest","uptime_s":${uptime},"mode":"$(json_escape "${MODE}")","state":"$(json_escape "${state}")","sdi_signal":${sdi_sig},"device":"$(json_escape "${DECKLINK_DEVICE}")","format":"$(json_escape "${FORMAT_CODE}")","multicast":"${MULTICAST_IP}:${MULTICAST_PORT}","ffmpeg":${ff_detail},"switching":{"ok_count":${OK_COUNT},"bad_count":${BAD_COUNT},"probe_ok":${PROBE_OK_COUNT},"probe_bad":${PROBE_BAD_COUNT}},"restarts":{"consecutive_failures":${CONSEC_FAILS},"backoff_s":${BACKOFF},"total_mode_starts":${TOTAL_MODE_STARTS},"total_ffmpeg_exits":${TOTAL_FFMPEG_EXITS},"last_exit_rc":${LAST_EXIT_RC}}}
EOF
}

# ---------- FFmpeg commands (multicast output) ----------
build_ffmpeg_live_cmd() {
  local vf
  vf="$(build_live_vf)"
  local bitrate="${BITRATE_MAX_K}"
  local bufsize="${BUFSIZE_MAX_K}"

  cat <<EOF
"${FFMPEG_BIN}" -hide_banner -loglevel info \\
  -thread_queue_size 8192 \\
  -fflags +genpts -use_wallclock_as_timestamps 1 \\
  -f decklink -video_input ${VIDEO_INPUT} -audio_input ${AUDIO_INPUT} \\
  -i "${DECKLINK_DEVICE}" \\
  -vf "${vf}" \\
  -af "aresample=async=1:first_pts=0" \\
  -color_primaries ${COLOR_PRIMARIES} -color_trc ${COLOR_TRC} -colorspace ${COLOR_SPACE} -color_range tv \\
  -c:v h264_videotoolbox -profile:v high -level 4.2 \\
  -b:v ${bitrate} -maxrate ${bitrate} -bufsize ${bufsize} \\
  -g ${GOP} -keyint_min ${KEYINT_MIN} \\
  -pix_fmt yuv420p \\
  $(audio_args) \\
  -stats_period 1 -progress "${PROGRESS_FILE}" \\
  -mpegts_flags pat_pmt_at_frames \\
  -f mpegts -muxrate 18M \\
  "${MULTICAST_OUTPUT}"
EOF
}

build_ffmpeg_standby_cmd() {
  local logo_input=""
  local overlay_prefix=""

  if [[ "${LOGO_ENABLE}" == "true" && -n "${LOGO_PATH:-}" && -f "${LOGO_PATH}" ]]; then
    logo_input="-i \"${LOGO_PATH}\""
    overlay_prefix="[0:v][1:v]overlay=${LOGO_X}:${LOGO_Y},"
  fi

  local standby_res="${OUTPUT_RESOLUTION:-1920x1080}"

  cat <<EOF
TZ="${CLOCK_TZ}" "${FFMPEG_BIN}" -hide_banner -loglevel info \\
  -f lavfi -i "color=c=${STANDBY_BG_COLOR}:s=${standby_res}:r=${STANDBY_FPS}" \\
  ${logo_input} \\
  -f lavfi -i "anullsrc=channel_layout=stereo:sample_rate=${AUDIO_RATE}" \\
  -filter_complex "${overlay_prefix}drawtext=fontfile=${FONT_FILE}:text='${STANDBY_TITLE}':x=${TEXT_X}:y=${TEXT_Y}:fontsize=${TITLE_FONTSIZE}:fontcolor=white:box=1:boxcolor=black@0.35:boxborderw=18,drawtext=fontfile=${FONT_FILE}:text='%{localtime\\:%Y-%m-%d %H\\\\:%M\\\\:%S}':x=${TEXT_X}:y=${TEXT_Y}+${CLOCK_DY}:fontsize=${CLOCK_FONTSIZE}:fontcolor=white:box=1:boxcolor=black@0.25:boxborderw=14,drawtext=fontfile=${FONT_FILE}:text='${STANDBY_SUBTITLE}':x=${TEXT_X}:y=${TEXT_Y}+${SUBTITLE_DY}:fontsize=${SUBTITLE_FONTSIZE}:fontcolor=white@0.95" \\
  -map 0:v:0 -map 2:a:0 \\
  -c:v h264_videotoolbox -profile:v high -level 4.2 \\
  -b:v ${BITRATE_MAX_K} -maxrate ${BITRATE_MAX_K} -bufsize ${BUFSIZE_MAX_K} \\
  -g ${GOP} -keyint_min ${KEYINT_MIN} -pix_fmt yuv420p \\
  $(audio_args) \\
  -stats_period 1 -progress "${PROGRESS_FILE}" \\
  -mpegts_flags pat_pmt_at_frames \\
  -f mpegts -muxrate 18M \\
  "${MULTICAST_OUTPUT}"
EOF
}

# ---------- Main ----------
preflight() {
  require_bin "${FFMPEG_BIN}"
  require_bin /usr/bin/pkill

  if [[ -n "${FONT_FILE:-}" && ! -f "${FONT_FILE}" ]]; then
    log_event "WARN" "standby_font_missing" "Standby FONT_FILE missing" "\"font\":\"$(json_escape "${FONT_FILE}")\""
  fi
  if [[ "${LOGO_ENABLE}" == "true" && -n "${LOGO_PATH:-}" && ! -f "${LOGO_PATH}" ]]; then
    log_event "WARN" "standby_logo_missing" "Logo file missing" "\"logo\":\"$(json_escape "${LOGO_PATH}")\""
  fi

  echo $$ > "${LOG_DIR}/ingest.pid"
  echo "-1" > "${SDI_SIGNAL_FILE}"

  log_event "INFO" "boot" "yt-sdi-ingest starting" "\"multicast\":\"${MULTICAST_IP}:${MULTICAST_PORT}\""
  run_alert "boot" "{}"
  write_status "boot" "{}"
  write_metrics_snapshot "boot" "{\"pid\":$$}"
}

main() {
  umask 022
  preflight
  supervisor_loop build_ffmpeg_live_cmd build_ffmpeg_standby_cmd
}

main "$@"

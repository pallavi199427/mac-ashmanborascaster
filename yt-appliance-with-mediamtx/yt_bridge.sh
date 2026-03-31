#!/usr/bin/env bash
set -uo pipefail

###############################################################################
# yt_bridge.sh — Multicast to RTSP bridge (audio transcode for MediaMTX)
#
# Reads the MPEG-TS multicast stream from the ingest process, copies video,
# transcodes audio to Opus (native WebRTC codec), and pushes to MediaMTX via RTSP.
# MediaMTX then serves this as a WebRTC stream for low-latency input preview.
#
# Simple watchdog loop: if FFmpeg exits, restart after 2 seconds.
###############################################################################

CONFIG_FILE="/etc/yt-sdi-streamer.conf"
[[ -f "${CONFIG_FILE}" ]] || { echo "Missing ${CONFIG_FILE}" >&2; exit 2; }

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

# ---------- Config ----------
LOG_DIR="${LOG_DIR:-/var/log/yt-sdi-streamer}"
STATUS_FILE="${LOG_DIR}/bridge_status.json"
BRIDGE_LOG="${LOG_DIR}/bridge_ffmpeg.log"

MULTICAST_IP="${MULTICAST_IP:-239.20.0.10}"
MULTICAST_PORT="${MULTICAST_PORT:-5000}"
MEDIAMTX_RTSP_URL="${MEDIAMTX_RTSP_URL:-rtsp://localhost:8554/stream}"

MULTICAST_INPUT="udp://${MULTICAST_IP}:${MULTICAST_PORT}?fifo_size=1000000&overrun_nonfatal=1&buffer_size=2097152&timeout=5000000"

FFMPEG_BIN="${FFMPEG_BIN:-/usr/local/bin/ffmpeg}"

mkdir -p "${LOG_DIR}"

FFMPEG_PID=""

cleanup() {
    if [[ -n "${FFMPEG_PID}" ]] && kill -0 "${FFMPEG_PID}" 2>/dev/null; then
        kill -TERM "${FFMPEG_PID}" 2>/dev/null
        wait "${FFMPEG_PID}" 2>/dev/null
    fi
    exit 0
}

trap cleanup SIGTERM SIGINT

log_status() {
    local ts state
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    state="$1"
    cat <<EOJSON > "${STATUS_FILE}.tmp"
{
    "ts": "${ts}",
    "service": "yt-bridge",
    "type": "bridge",
    "state": "${state}",
    "pid": $$
}
EOJSON
    mv "${STATUS_FILE}.tmp" "${STATUS_FILE}"
}

log_status "starting"
sleep 1

echo "Starting YT Bridge (multicast -> RTSP -> MediaMTX)..."

while true; do
    log_status "running"

    "${FFMPEG_BIN}" -hide_banner -loglevel warning \
      -fflags +genpts+discardcorrupt \
      -err_detect ignore_err \
      -analyzeduration 5000000 -probesize 10000000 \
      -f mpegts \
      -i "${MULTICAST_INPUT}" \
      -c:v copy \
      -bsf:v "extract_extradata=remove=0,dump_extra=freq=keyframe" \
      -c:a libopus -ar 48000 -ac 2 -b:a 128k \
      -avoid_negative_ts make_zero \
      -max_interleave_delta 0 \
      -flags +global_header \
      -rtsp_transport tcp \
      -f rtsp "${MEDIAMTX_RTSP_URL}" >> "${BRIDGE_LOG}" 2>&1 &

    FFMPEG_PID=$!

    # Heartbeat: keep status file fresh while ffmpeg is running
    while kill -0 $FFMPEG_PID 2>/dev/null; do
        log_status "running"
        sleep 3
    done

    wait $FFMPEG_PID
    RC=$?
    log_status "restarting"
    echo "Bridge exited with $RC, restarting in 2s..."
    sleep 2
done

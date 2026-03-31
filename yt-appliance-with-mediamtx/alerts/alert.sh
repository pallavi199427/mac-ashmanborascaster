#!/usr/bin/env bash
set -euo pipefail

# Usage: alert.sh EVENT JSON_DETAIL
EVENT="${1:-unknown}"
DETAIL="${2:-{}}"

# Environment (provided by streamer):
# ALERT_TS ALERT_EVENT ALERT_MODE ALERT_BITRATE ALERT_DEVICE ALERT_FORMAT ALERT_ENDPOINT ALERT_DETAIL

LOG_DIR="/var/log/yt-sdi-streamer"
ALERT_LOG="${LOG_DIR}/alerts_events.jsonl"
mkdir -p "${LOG_DIR}"

ts="${ALERT_TS:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"

echo "{\"ts\":\"${ts}\",\"event\":\"${EVENT}\",\"mode\":\"${ALERT_MODE:-}\",\"bitrate\":\"${ALERT_BITRATE:-}\",\"device\":\"${ALERT_DEVICE:-}\",\"format\":\"${ALERT_FORMAT:-}\",\"endpoint\":\"${ALERT_ENDPOINT:-}\",\"detail\":${DETAIL}}" >> "${ALERT_LOG}"

HOOK="/usr/local/lib/yt-sdi-streamer/alerts/webhook.sh"
if [[ -x "${HOOK}" ]]; then
  "${HOOK}" "${EVENT}" "${DETAIL}" || true
fi

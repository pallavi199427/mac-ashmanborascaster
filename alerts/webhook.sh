#!/usr/bin/env bash
set -euo pipefail

EVENT="${1:-unknown}"
DETAIL="${2:-{}}"

WEBHOOK_URL="${WEBHOOK_URL:-}"
[[ -n "${WEBHOOK_URL}" ]] || exit 0

payload=$(cat <<JSON
{
  "ts": "${ALERT_TS:-}",
  "event": "${EVENT}",
  "mode": "${ALERT_MODE:-}",
  "bitrate": "${ALERT_BITRATE:-}",
  "device": "${ALERT_DEVICE:-}",
  "format": "${ALERT_FORMAT:-}",
  "endpoint": "${ALERT_ENDPOINT:-}",
  "detail": ${DETAIL}
}
JSON
)

curl -fsS -X POST -H "Content-Type: application/json" -d "${payload}" "${WEBHOOK_URL}" >/dev/null

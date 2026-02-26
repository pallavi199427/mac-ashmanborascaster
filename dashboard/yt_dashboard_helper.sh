#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# yt_dashboard_helper.sh — Privileged helper for the web dashboard
#
# Called via sudo from the unprivileged Flask process.
# Allowed operations: reading/writing STREAM_KEY and BITRATE.
###############################################################################

CONF="/etc/yt-sdi-streamer.conf"

cmd="${1:-}"

case "${cmd}" in
  read-key)
    grep '^STREAM_KEY=' "${CONF}" | head -1 | sed 's/^STREAM_KEY="//' | sed 's/".*//'
    ;;
  write-key)
    key="${2:-}"
    if [[ -z "${key}" ]]; then
      echo "Missing key argument" >&2
      exit 1
    fi
    # Strict validation: only allow alphanumeric and dashes
    if [[ ! "${key}" =~ ^[a-zA-Z0-9-]{4,64}$ ]]; then
      echo "Invalid key format" >&2
      exit 1
    fi
    sed -i '' "s/^STREAM_KEY=.*/STREAM_KEY=\"${key}\"  # SECRET/" "${CONF}"
    echo "OK"
    ;;
  read-bitrate)
    grep '^BITRATE_MAX_K=' "${CONF}" | head -1 | sed 's/^BITRATE_MAX_K=//' | sed 's/#.*//' | tr -d ' "'
    ;;
  write-bitrate)
    bitrate="${2:-}"
    if [[ -z "${bitrate}" ]]; then
      echo "Missing bitrate argument" >&2
      exit 1
    fi
    # Validate: digits optionally followed by 'k' e.g. 4000k, 2500k, 8000
    if [[ ! "${bitrate}" =~ ^[0-9]{1,6}k?$ ]]; then
      echo "Invalid bitrate format (e.g. 4000k)" >&2
      exit 1
    fi
    sed -i '' "s/^BITRATE_MAX_K=.*/BITRATE_MAX_K=${bitrate}/" "${CONF}"
    sed -i '' "s/^BUFSIZE_MAX_K=.*/BUFSIZE_MAX_K=${bitrate}/" "${CONF}"
    echo "OK"
    ;;
  read-playback-url)
    grep '^PLAYBACK_URL=' "${CONF}" | head -1 | sed 's/^PLAYBACK_URL="//' | sed 's/".*//'
    ;;
  write-playback-url)
    url="${2:-}"
    if [[ -z "${url}" ]]; then
      echo "Missing url argument" >&2
      exit 1
    fi
    # Validate: must start with http:// or https://
    # Note: regex stored in variable to avoid bash 3.2 parse errors with special chars
    local url_re='^https?://.+$'
    if [[ ! "${url}" =~ $url_re ]]; then
      echo "Invalid URL format (must start with http:// or https://)" >&2
      exit 1
    fi
    sed -i '' "s|^PLAYBACK_URL=.*|PLAYBACK_URL=\"${url}\"|" "${CONF}"
    echo "OK"
    ;;
  *)
    echo "Usage: $0 {read-key|write-key KEY|read-bitrate|write-bitrate RATE|read-playback-url|write-playback-url URL}" >&2
    exit 1
    ;;
esac

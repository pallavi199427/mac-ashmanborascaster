#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# yt_dashboard_helper.sh — Privileged helper for the web dashboard
#
# Called via sudo from the unprivileged Flask process.
# Allowed operations: reading/writing STREAM_KEY and BITRATE.
###############################################################################

CONF="/etc/yt-sdi-streamer.conf"
PROFILES="/etc/yt-sdi-streamer-profiles.json"

# Initialize default profiles file if missing
if [[ ! -f "${PROFILES}" ]]; then
  cat > "${PROFILES}" << 'DEFAULTEOF'
{
  "active": "standard",
  "profiles": {
    "low":      { "name": "Low",      "platform": "youtube", "stream_key": "", "bitrate": "2500k", "playback_url": "", "resolution": "1920x1080" },
    "standard": { "name": "Standard", "platform": "youtube", "stream_key": "", "bitrate": "4000k", "playback_url": "", "resolution": "1920x1080" },
    "high":     { "name": "High",     "platform": "youtube", "stream_key": "", "bitrate": "8000k", "playback_url": "", "resolution": "1920x1080" }
  }
}
DEFAULTEOF
  chmod 600 "${PROFILES}"
fi

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
  read-resolution)
    grep '^OUTPUT_RESOLUTION=' "${CONF}" | head -1 | sed 's/^OUTPUT_RESOLUTION=//' | sed 's/#.*//' | tr -d ' "'
    ;;
  write-resolution)
    res="${2:-}"
    if [[ -z "${res}" ]]; then
      echo "Missing resolution argument" >&2
      exit 1
    fi
    # Validate: WxH format, e.g. 1920x1080, 1280x720
    if [[ ! "${res}" =~ ^[0-9]{2,4}x[0-9]{2,4}$ ]]; then
      echo "Invalid resolution format (e.g. 1920x1080)" >&2
      exit 1
    fi
    sed -i '' "s/^OUTPUT_RESOLUTION=.*/OUTPUT_RESOLUTION=\"${res}\"/" "${CONF}"
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
    # Ensure 'k' suffix is always present (ffmpeg treats bare number as bits, not kbits)
    [[ "${bitrate}" != *k ]] && bitrate="${bitrate}k"
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
  read-profiles)
    cat "${PROFILES}"
    ;;
  write-profile)
    # Usage: write-profile <json-string>
    # Expects full profiles JSON on stdin or as arg $2
    json="${2:-}"
    if [[ -z "${json}" ]]; then
      echo "Missing JSON argument" >&2
      exit 1
    fi
    # Validate it's parseable JSON (python is available on macOS)
    if ! echo "${json}" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
      echo "Invalid JSON" >&2
      exit 1
    fi
    echo "${json}" > "${PROFILES}"
    chmod 600 "${PROFILES}"
    echo "OK"
    ;;
  switch-profile)
    # Usage: switch-profile <profile-id>
    # Sets active profile and syncs its values to the main .conf
    prof_id="${2:-}"
    if [[ -z "${prof_id}" ]]; then
      echo "Missing profile ID" >&2
      exit 1
    fi
    # Read profile data using python3
    result=$(python3 -c "
import json, sys
with open('${PROFILES}') as f:
    data = json.load(f)
p = data['profiles'].get('${prof_id}')
if not p:
    print('ERROR:Profile not found', file=sys.stderr)
    sys.exit(1)
data['active'] = '${prof_id}'
with open('${PROFILES}', 'w') as f:
    json.dump(data, f, indent=2)
print(p.get('stream_key', ''))
print(p.get('bitrate', '4000k'))
print(p.get('playback_url', ''))
print(p.get('resolution', '1920x1080'))
") || { echo "Profile not found" >&2; exit 1; }
    # Parse the 4 lines
    sk=$(echo "${result}" | sed -n '1p')
    br=$(echo "${result}" | sed -n '2p')
    pu=$(echo "${result}" | sed -n '3p')
    res=$(echo "${result}" | sed -n '4p')
    # Sync to .conf
    if [[ -n "${sk}" ]]; then
      sed -i '' "s/^STREAM_KEY=.*/STREAM_KEY=\"${sk}\"  # SECRET/" "${CONF}"
    fi
    if [[ -n "${br}" ]]; then
      # Ensure 'k' suffix is always present
      [[ "${br}" != *k ]] && br="${br}k"
      sed -i '' "s/^BITRATE_MAX_K=.*/BITRATE_MAX_K=${br}/" "${CONF}"
      sed -i '' "s/^BUFSIZE_MAX_K=.*/BUFSIZE_MAX_K=${br}/" "${CONF}"
    fi
    if [[ -n "${pu}" ]]; then
      sed -i '' "s|^PLAYBACK_URL=.*|PLAYBACK_URL=\"${pu}\"|" "${CONF}"
    fi
    if [[ -n "${res}" ]]; then
      sed -i '' "s/^OUTPUT_RESOLUTION=.*/OUTPUT_RESOLUTION=\"${res}\"/" "${CONF}"
    fi
    echo "OK"
    ;;
  read-dashboard-creds)
    grep '^DASHBOARD_USER=' "${CONF}" | head -1 | sed 's/^DASHBOARD_USER="//' | sed 's/".*//'
    grep '^DASHBOARD_PASS=' "${CONF}" | head -1 | sed 's/^DASHBOARD_PASS="//' | sed 's/".*//'
    ;;
  *)
    echo "Usage: $0 {read-key|write-key|read-resolution|write-resolution|read-bitrate|write-bitrate|read-playback-url|write-playback-url|read-profiles|write-profile|switch-profile|read-dashboard-creds}" >&2
    exit 1
    ;;
esac

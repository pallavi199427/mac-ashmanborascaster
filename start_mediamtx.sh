#!/bin/bash
# MediaMTX Startup Wrapper (macOS)
# ---------------------------------
# Injects the LAN IP as a WebRTC ICE host candidate so loopback (127.0.0.1)
# is never offered. The STUN server in the config resolves the public/WAN IP
# automatically at connection time — works on any network without hardcoding.

CONFIG="/usr/local/lib/yt-sdi-streamer/mediamtx.yml"
RUNTIME_CONFIG="/usr/local/lib/yt-sdi-streamer/mediamtx_runtime.yml"

DEFAULT_IFACE=$(/sbin/route -n get default 2>/dev/null | awk '/interface:/{print $2}')
DEFAULT_IP=""
if [[ -n "${DEFAULT_IFACE}" ]]; then
    DEFAULT_IP=$(/usr/sbin/ipconfig getifaddr "${DEFAULT_IFACE}" 2>/dev/null)
fi

if [[ -z "${DEFAULT_IP}" ]]; then
    echo "WARNING: Could not detect LAN IP, falling back to interface scanning"
    sed "s/^webrtcIPsFromInterfaces: no/webrtcIPsFromInterfaces: yes/" "$CONFIG" > "$RUNTIME_CONFIG"
else
    echo "Detected LAN IP: ${DEFAULT_IP}"
    sed "s/^webrtcAdditionalHosts: \[\]/webrtcAdditionalHosts:\n  - ${DEFAULT_IP}/" "$CONFIG" > "$RUNTIME_CONFIG"
fi

exec /usr/local/bin/mediamtx "$RUNTIME_CONFIG"

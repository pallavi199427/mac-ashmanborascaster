#!/bin/bash
# MediaMTX Startup Wrapper (macOS)
# ---------------------------------
# Detects the default network interface IP and injects it into
# the mediamtx config as webrtcAdditionalHosts, so that loopback
# (127.0.0.1) is never offered as a WebRTC ICE candidate.

CONFIG="/usr/local/lib/yt-sdi-streamer/mediamtx.yml"
RUNTIME_CONFIG="/usr/local/lib/yt-sdi-streamer/mediamtx_runtime.yml"

# Get the default route interface on macOS
DEFAULT_IFACE=$(/sbin/route -n get default 2>/dev/null | awk '/interface:/{print $2}')
DEFAULT_IP=""

if [[ -n "${DEFAULT_IFACE}" ]]; then
    DEFAULT_IP=$(/usr/sbin/ipconfig getifaddr "${DEFAULT_IFACE}" 2>/dev/null)
fi

if [[ -z "${DEFAULT_IP}" ]]; then
    echo "WARNING: Could not detect default interface IP, falling back to original config"
    exec /usr/local/bin/mediamtx "$CONFIG"
fi

echo "Detected default IP: $DEFAULT_IP"

# Generate runtime config with the real IP injected
sed "s/^webrtcAdditionalHosts: \[\]/webrtcAdditionalHosts:\n  - $DEFAULT_IP/" "$CONFIG" > "$RUNTIME_CONFIG"

exec /usr/local/bin/mediamtx "$RUNTIME_CONFIG"

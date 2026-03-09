#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# deploy.sh — Deploy yt-sdi-streamer + dashboard to this Mac
#
# Run from the repo root on the Mac:
#   sudo bash deploy.sh
###############################################################################

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Error: Run with sudo: sudo bash $0"
  exit 1
fi

echo "=== YT SDI Streamer — Deploy ==="
echo

# ── 1. Detect active Ethernet interface ────────────────────────────────────
echo "[..] Detecting Ethernet interface..."

IFACE=""
SERVICE_NAME=""

# Walk all hardware ports; find a WIRED Ethernet port that is active.
# Explicitly skip Wi-Fi, Thunderbolt Bridge, iPhone USB, and any port
# whose name contains "Wi-Fi" or "Wireless".
while IFS= read -r line; do
  if [[ "${line}" =~ ^"Hardware Port:" ]]; then
    port_name="${line#Hardware Port: }"
    dev=""
  elif [[ "${line}" =~ ^"Device:" ]]; then
    dev="${line#Device: }"
  elif [[ "${line}" =~ ^"Ethernet Address:" ]]; then
    [[ -z "${dev:-}" ]] && continue

    # Skip known wireless / virtual port types
    if echo "${port_name}" | grep -qiE "wi-?fi|wireless|thunderbolt bridge|iphone|bluetooth"; then
      continue
    fi

    # Skip the Wi-Fi device (en0 on most Macs) by checking mediatype
    if /sbin/ifconfig "${dev}" 2>/dev/null | grep -q "type: Wi-Fi"; then
      continue
    fi

    # Must be active (link up)
    if /sbin/ifconfig "${dev}" 2>/dev/null | grep -q "status: active"; then
      IFACE="${dev}"
      SERVICE_NAME="${port_name}"
      break
    fi
  fi
done < <(/usr/sbin/networksetup -listallhardwareports 2>/dev/null)

if [[ -z "${IFACE}" ]]; then
  echo "[WARN] Could not auto-detect an active wired Ethernet interface."
  echo
  echo "       All hardware ports found:"
  /usr/sbin/networksetup -listallhardwareports 2>/dev/null | grep -E "^Hardware Port:|^Device:|^Ethernet" | sed 's/^/         /'
  echo
  read -r -p "       Enter the Network Service name from above (e.g. USB 10/100/1000 LAN): " SERVICE_NAME
  # Resolve device name from service name
  IFACE="$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null \
    | awk -v svc="${SERVICE_NAME}" '/^Hardware Port:/{found=($0 ~ svc)} found && /^Device:/{print $2; exit}')" || true
  if [[ -z "${IFACE}" ]]; then
    echo "[ERROR] Could not resolve interface for \"${SERVICE_NAME}\". Aborting."
    exit 1
  fi
fi

# If we still don't have a service name, resolve it
if [[ -z "${SERVICE_NAME}" ]]; then
  SERVICE_NAME="$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null \
    | awk -v dev="${IFACE}" '/^Hardware Port:/{name=substr($0,17)} /^Device: /{ if ($2==dev) {print name; exit}}')" || true
fi
[[ -z "${SERVICE_NAME}" ]] && SERVICE_NAME="${IFACE}"

echo "[OK] Interface: ${IFACE}  |  Service: \"${SERVICE_NAME}\""
echo

# ── 2. Install streamer files ───────────────────────────────────────────────
echo "[..] Installing streamer..."
bash "${HERE}/install_yt_sdi_streamer.sh"
echo "[OK] Streamer installed"
echo

# ── 3. Install dashboard files ─────────────────────────────────────────────
echo "[..] Installing dashboard..."
bash "${HERE}/dashboard/install_dashboard.sh"
echo "[OK] Dashboard installed"
echo

# ── 4. Patch NETWORK_SERVICE in /etc/yt-sdi-streamer.conf ──────────────────
CONF="/etc/yt-sdi-streamer.conf"
echo "[..] Patching NETWORK_SERVICE in ${CONF}..."

# Update NETWORK_SERVICE
sed -i '' "s|^NETWORK_SERVICE=.*|NETWORK_SERVICE=\"${SERVICE_NAME}\"|" "${CONF}"

# Update SERVICE_ORDER — put detected service first, keep rest as fallbacks
sed -i '' "s|^SERVICE_ORDER=.*|SERVICE_ORDER=(\"${SERVICE_NAME}\" \"Wi-Fi\" \"Thunderbolt Bridge\" \"iPhone USB\")|" "${CONF}"

echo "[OK] NETWORK_SERVICE set to \"${SERVICE_NAME}\""
echo

# ── 5. TCP keepalive ────────────────────────────────────────────────────────
echo "[..] Setting TCP keepalive..."

# These sysctl values persist only until reboot via sysctl directly.
# We persist them via /etc/sysctl.conf so they survive reboots.
SYSCTL_CONF="/etc/sysctl.conf"

apply_sysctl() {
  local key="$1" val="$2"
  sysctl -w "${key}=${val}" >/dev/null 2>&1 || true

  # Persist in /etc/sysctl.conf
  if [[ -f "${SYSCTL_CONF}" ]] && grep -q "^${key}=" "${SYSCTL_CONF}" 2>/dev/null; then
    sed -i '' "s|^${key}=.*|${key}=${val}|" "${SYSCTL_CONF}"
  else
    echo "${key}=${val}" >> "${SYSCTL_CONF}"
  fi
}

# Start probing after 15s idle, then probe every 10s, drop after 3 missed probes
apply_sysctl "net.inet.tcp.keepidle"   "15000"   # ms idle before first probe
apply_sysctl "net.inet.tcp.keepintvl"  "10000"   # ms between probes
apply_sysctl "net.inet.tcp.keepcnt"    "3"       # probes before drop
apply_sysctl "net.inet.tcp.always_keepalive" "1" # enable for all TCP sockets

echo "[OK] TCP keepalive applied and persisted to ${SYSCTL_CONF}"
echo

# ── Done ────────────────────────────────────────────────────────────────────
echo "=== Deploy complete ==="
echo "  Interface : ${IFACE}"
echo "  Service   : ${SERVICE_NAME}"
echo "  Dashboard : http://$(hostname -s).local:8080"
echo "  Logs      : /var/log/yt-sdi-streamer/"
echo

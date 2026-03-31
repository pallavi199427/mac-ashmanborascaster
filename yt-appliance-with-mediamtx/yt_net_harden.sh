#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# yt_net_harden.sh — One-shot boot-time network hardening
#
# Runs once at system boot via LaunchDaemon. Enforces network service order,
# DNS servers, Wi-Fi disable, sleep disable, and MTU. Waits for DNS to
# resolve the YouTube RTMP endpoint, then exits.
#
# Writes /var/run/yt-net-hardened stamp file on completion.
###############################################################################

CONFIG_FILE="/etc/yt-sdi-streamer.conf"
[[ -f "${CONFIG_FILE}" ]] || { echo "Missing ${CONFIG_FILE}" >&2; exit 2; }

# shellcheck disable=SC1090
source "${CONFIG_FILE}"

LOG_DIR="${LOG_DIR:-/var/log/yt-sdi-streamer}"
STAMP_FILE="/var/run/yt-net-hardened"

mkdir -p "${LOG_DIR}"

log() {
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") [net-harden] $*" >> "${LOG_DIR}/netharden.log"
}

# ---------- Privilege helpers ----------
init_privs() {
  if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
    return 0
  fi
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

# ---------- Network hardening ----------
harden_network() {
  if [[ "${DO_NETWORK_HARDENING:-false}" != "true" ]]; then
    log "Network hardening disabled in config; skipping"
    return 0
  fi

  log "Starting network hardening"
  init_privs

  if [[ "$(id -u)" -ne 0 && -z "${SUDO}" ]]; then
    log "WARN: Not running as root and sudo -n unavailable; skipping"
    return 0
  fi

  if [[ "${ENFORCE_SERVICE_ORDER:-false}" == "true" ]]; then
    local order=(/usr/sbin/networksetup -ordernetworkservices)
    local svc
    for svc in "${SERVICE_ORDER[@]}"; do
      order+=("${svc}")
    done
    run_root "${order[@]}" >/dev/null 2>&1 || log "WARN: Could not enforce network service order"
  fi

  if [[ "${SET_DNS:-false}" == "true" ]]; then
    local dns=(/usr/sbin/networksetup -setdnsservers "${NETWORK_SERVICE}")
    local d
    for d in "${DNS_SERVERS[@]}"; do
      dns+=("${d}")
    done
    run_root "${dns[@]}" >/dev/null 2>&1 || log "WARN: Could not set DNS servers"
    run_root /usr/bin/dscacheutil -flushcache >/dev/null 2>&1 || true
    run_root /usr/bin/killall -HUP mDNSResponder >/dev/null 2>&1 || true
  fi

  if [[ "${DISABLE_WIFI_DURING_RUN:-false}" == "true" ]]; then
    run_root /usr/sbin/networksetup -setairportpower "Wi-Fi" off >/dev/null 2>&1 || log "WARN: Could not disable Wi-Fi"
  fi

  if [[ "${DISABLE_SLEEP:-false}" == "true" ]]; then
    run_root /usr/bin/pmset -a sleep 0 disksleep 0 displaysleep 0 \
      powernap 0 womp 0 autopoweroff 0 standby 0 >/dev/null 2>&1 || log "WARN: Could not set pmset"
  fi

  if [[ -n "${MTU_VALUE:-}" ]]; then
    run_root /usr/sbin/networksetup -setMTU "${NETWORK_SERVICE}" "${MTU_VALUE}" >/dev/null 2>&1 || log "WARN: Could not set MTU"
  fi

  log "Network hardening complete"
}

# ---------- DNS wait ----------
wait_for_dns() {
  local host="a.rtmp.youtube.com"
  local max_wait=60
  local i=0
  log "Waiting for DNS to resolve ${host}"
  while ! dscacheutil -q host -a name "${host}" 2>/dev/null | grep -q "ip_address"; do
    i=$((i+1))
    if [[ "${i}" -ge "${max_wait}" ]]; then
      log "WARN: DNS did not resolve ${host} after ${max_wait}s; continuing anyway"
      return 0
    fi
    sleep 1
  done
  log "DNS resolved ${host} after ${i}s"
}

# ---------- Multicast route ----------
add_multicast_route() {
  log "Adding multicast route 239.0.0.0/8 via loopback"
  run_root /sbin/route add -net 239.0.0.0/8 127.0.0.1 >/dev/null 2>&1 || \
    log "WARN: Could not add multicast route (may already exist)"
  log "Multicast route set"
}

# ---------- PF multicast block ----------
add_pf_multicast_block() {
  local pf_conf="/etc/pf.conf"

  # Resolve BSD interface name from NETWORK_SERVICE (e.g. "USB 10/100/1000 LAN" → "en0")
  local iface
  iface=$(/usr/sbin/networksetup -listallhardwareports 2>/dev/null \
    | awk -v svc="${NETWORK_SERVICE}" '
        /^Hardware Port:/ { found = ($0 ~ svc) }
        found && /^Device:/ { print $2; exit }
      ')

  if [[ -z "${iface}" ]]; then
    log "WARN: Could not resolve interface for '${NETWORK_SERVICE}'; skipping pf rules"
    return 0
  fi

  log "Resolved interface for '${NETWORK_SERVICE}': ${iface}"
  local marker="block out quick on ${iface} proto udp to 224.0.0.0/4"

  if grep -qF "${marker}" "${pf_conf}" 2>/dev/null; then
    log "PF multicast block rules already present for ${iface}"
  else
    # Remove any stale multicast block rules for a different interface
    if grep -q "proto udp to 224.0.0.0/4" "${pf_conf}" 2>/dev/null; then
      log "Removing stale PF multicast block rules"
      run_root sed -i '' '/proto udp to 224\.0\.0\.0\/4/d' "${pf_conf}" 2>/dev/null || true
      run_root sed -i '' '/Block all multicast on .* (belt-and-suspenders/d' "${pf_conf}" 2>/dev/null || true
    fi

    log "Adding PF multicast block rules for ${iface} to ${pf_conf}"
    run_root tee -a "${pf_conf}" >/dev/null <<PF_RULES

# Block all multicast on ${iface} (belt-and-suspenders with loopback route)
block out quick on ${iface} proto udp to 224.0.0.0/4
block in  quick on ${iface} proto udp to 224.0.0.0/4
PF_RULES
  fi

  run_root /sbin/pfctl -f "${pf_conf}" 2>/dev/null || log "WARN: Could not reload pf rules"
  run_root /sbin/pfctl -e 2>/dev/null || true
  log "PF multicast block enabled on ${iface}"
}

# ---------- Main ----------
main() {
  log "Boot-time network hardening starting"
  rm -f "${STAMP_FILE}" 2>/dev/null || true

  harden_network
  add_multicast_route
  add_pf_multicast_block
  wait_for_dns

  date -u +"%Y-%m-%dT%H:%M:%SZ" > "${STAMP_FILE}"
  log "Done — stamp written to ${STAMP_FILE}"
}

main "$@"

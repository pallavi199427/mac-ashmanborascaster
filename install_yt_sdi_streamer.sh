#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# install_yt_sdi_streamer.sh — Install all YT appliance services
#
# Installs: ingest, bridge, mediamtx, uplink (streamer), ytctl, config, alerts
###############################################################################

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Service labels
LABEL_INGEST="com.kalaignar.yt-ingest"
LABEL_BRIDGE="com.kalaignar.yt-bridge"
LABEL_MEDIAMTX="com.kalaignar.mediamtx"
LABEL_UPLINK="com.kalaignar.yt-sdi-streamer"

# Source files
COMMON_SRC="${HERE}/yt_common.sh"
INGEST_SRC="${HERE}/yt_sdi_ingest.sh"
BRIDGE_SRC="${HERE}/yt_bridge.sh"
MEDIAMTX_START_SRC="${HERE}/start_mediamtx.sh"
MEDIAMTX_YML_SRC="${HERE}/mediamtx.yml"
UPLINK_SRC="${HERE}/yt_sdi_streamer.sh"
CONF_SRC="${HERE}/yt-sdi-streamer.conf"
YTCTL_SRC="${HERE}/ytctl.sh"
NEWSYSLOG_SRC="${HERE}/newsyslog.yt-sdi-streamer.conf"
ALERTS_SRC_DIR="${HERE}/alerts"

PLIST_INGEST_SRC="${HERE}/com.kalaignar.yt-ingest.plist"
PLIST_BRIDGE_SRC="${HERE}/com.kalaignar.yt-bridge.plist"
PLIST_MEDIAMTX_SRC="${HERE}/com.kalaignar.mediamtx.plist"
PLIST_UPLINK_SRC="${HERE}/com.kalaignar.yt-sdi-streamer.plist"

# Destinations
BIN_DIR="/usr/local/bin"
LIB_DIR="/usr/local/lib/yt-sdi-streamer"
LOG_DIR="/var/log/yt-sdi-streamer"
STATE_DIR="/var/lib/yt-sdi-streamer"
CONF_DST="/etc/yt-sdi-streamer.conf"
NEWSYSLOG_DST="/etc/newsyslog.d/yt-sdi-streamer.conf"
PLIST_DIR="/Library/LaunchDaemons"

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
fi

need() { [[ -e "$1" ]] || { echo "Missing: $1" >&2; exit 1; }; }

need "${COMMON_SRC}"
need "${INGEST_SRC}"
need "${BRIDGE_SRC}"
need "${MEDIAMTX_START_SRC}"
need "${MEDIAMTX_YML_SRC}"
need "${UPLINK_SRC}"
need "${CONF_SRC}"
need "${YTCTL_SRC}"
need "${NEWSYSLOG_SRC}"
need "${ALERTS_SRC_DIR}"
need "${PLIST_INGEST_SRC}"
need "${PLIST_BRIDGE_SRC}"
need "${PLIST_MEDIAMTX_SRC}"
need "${PLIST_UPLINK_SRC}"

echo "== Installing YT appliance (ingest + bridge + mediamtx + uplink) =="
echo "This will require sudo."

sudo mkdir -p "${BIN_DIR}" "${LIB_DIR}" "${LIB_DIR}/alerts" "${LOG_DIR}" "${STATE_DIR}"

# ---------- Install scripts ----------
echo "Installing scripts..."
sudo install -m 755 "${COMMON_SRC}"        "${BIN_DIR}/yt_common.sh"
sudo install -m 755 "${INGEST_SRC}"        "${BIN_DIR}/yt_sdi_ingest.sh"
sudo install -m 755 "${BRIDGE_SRC}"        "${BIN_DIR}/yt_bridge.sh"
sudo install -m 755 "${MEDIAMTX_START_SRC}" "${BIN_DIR}/start_mediamtx.sh"
sudo install -m 755 "${UPLINK_SRC}"        "${BIN_DIR}/yt_sdi_streamer.sh"
sudo install -m 755 "${YTCTL_SRC}"         "${BIN_DIR}/ytctl"

# MediaMTX config
sudo install -m 644 "${MEDIAMTX_YML_SRC}" "${LIB_DIR}/mediamtx.yml"

# ---------- Install config ----------
if [[ -f "${CONF_DST}" && "${FORCE}" -ne 1 ]]; then
  echo "== Config exists at ${CONF_DST}; leaving it in place (use --force to overwrite) =="
else
  sudo install -m 600 "${CONF_SRC}" "${CONF_DST}"
fi

# ---------- Install alerts ----------
sudo rsync -a "${ALERTS_SRC_DIR}/" "${LIB_DIR}/alerts/"
sudo chmod -R 755 "${LIB_DIR}/alerts"

# ---------- Install LaunchDaemon plists ----------
echo "Installing LaunchDaemon plists..."

# Unload existing services first
for label in "${LABEL_UPLINK}" "${LABEL_BRIDGE}" "${LABEL_MEDIAMTX}" "${LABEL_INGEST}"; do
  sudo launchctl bootout system "${PLIST_DIR}/${label}.plist" >/dev/null 2>&1 || true
done
sleep 1

sudo install -m 644 "${PLIST_INGEST_SRC}"  "${PLIST_DIR}/${LABEL_INGEST}.plist"
sudo install -m 644 "${PLIST_BRIDGE_SRC}"   "${PLIST_DIR}/${LABEL_BRIDGE}.plist"
sudo install -m 644 "${PLIST_MEDIAMTX_SRC}" "${PLIST_DIR}/${LABEL_MEDIAMTX}.plist"
sudo install -m 644 "${PLIST_UPLINK_SRC}"   "${PLIST_DIR}/${LABEL_UPLINK}.plist"

sudo chown root:wheel "${PLIST_DIR}/${LABEL_INGEST}.plist" \
                       "${PLIST_DIR}/${LABEL_BRIDGE}.plist" \
                       "${PLIST_DIR}/${LABEL_MEDIAMTX}.plist" \
                       "${PLIST_DIR}/${LABEL_UPLINK}.plist" || true

# ---------- Newsyslog ----------
sudo mkdir -p /etc/newsyslog.d
sudo install -m 644 "${NEWSYSLOG_SRC}" "${NEWSYSLOG_DST}"

# ---------- Permissions ----------
sudo chmod 755 "${LOG_DIR}"
if [[ -f "${CONF_DST}" ]]; then
  sudo chown root:wheel "${CONF_DST}" || true
fi

if [[ ! -f "${STATE_DIR}/logo.png" ]]; then
  echo "NOTE: Place your logo at ${STATE_DIR}/logo.png (PNG recommended)."
fi

# ---------- Install MediaMTX binary ----------
MEDIAMTX_VERSION="v1.12.2"
MEDIAMTX_BIN="${BIN_DIR}/mediamtx"

if [[ -f "${MEDIAMTX_BIN}" && "${FORCE}" -ne 1 ]]; then
  echo "[OK] MediaMTX binary already exists at ${MEDIAMTX_BIN} (use --force to re-download)"
else
  echo "[..] Downloading MediaMTX ${MEDIAMTX_VERSION}..."

  # Detect architecture
  ARCH="$(uname -m)"
  case "${ARCH}" in
    arm64|aarch64) MTX_ARCH="arm64" ;;
    x86_64)        MTX_ARCH="amd64" ;;
    *)             echo "ERROR: Unsupported architecture: ${ARCH}"; exit 1 ;;
  esac

  MTX_URL="https://github.com/bluenviron/mediamtx/releases/download/${MEDIAMTX_VERSION}/mediamtx_${MEDIAMTX_VERSION}_darwin_${MTX_ARCH}.tar.gz"
  MTX_TMP="/tmp/mediamtx_install.tar.gz"

  if curl -fSL -o "${MTX_TMP}" "${MTX_URL}"; then
    # Extract just the mediamtx binary from the tarball
    tar xzf "${MTX_TMP}" -C /tmp mediamtx
    sudo install -m 755 /tmp/mediamtx "${MEDIAMTX_BIN}"
    rm -f "${MTX_TMP}" /tmp/mediamtx
    echo "[OK] MediaMTX ${MEDIAMTX_VERSION} installed to ${MEDIAMTX_BIN}"
  else
    echo ""
    echo "WARNING: Failed to download MediaMTX from ${MTX_URL}"
    echo "  Download manually and place at: ${MEDIAMTX_BIN}"
    echo ""
  fi
fi

# ---------- Load services ----------
echo "Loading services..."
for label in "${LABEL_INGEST}" "${LABEL_MEDIAMTX}" "${LABEL_BRIDGE}" "${LABEL_UPLINK}"; do
  sudo launchctl bootstrap system "${PLIST_DIR}/${label}.plist"
  sudo launchctl enable system/"${label}"
  echo "  Loaded ${label}"
done

echo ""
echo "== Installed =="
echo "Services:"
echo "  Ingest:   ${LABEL_INGEST}"
echo "  Bridge:   ${LABEL_BRIDGE}"
echo "  MediaMTX: ${LABEL_MEDIAMTX}"
echo "  Uplink:   ${LABEL_UPLINK}"
echo ""
echo "Logs:    ${LOG_DIR}"
echo "Control: ytctl [service] {start|stop|restart|status}"
echo ""
echo "To start all services:"
echo "  ytctl start"

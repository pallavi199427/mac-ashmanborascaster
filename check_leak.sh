#!/usr/bin/env bash
# =============================================================================
#  Streaming Appliance Health Check  v5.0
#
#  Runs all system checks, outputs to terminal, and optionally generates:
#    - streaming_report_TIMESTAMP.html     (full diagnostic report)
#    - fix_system_TIMESTAMP.sh             (kernel + firewall + power fixes)
#    - fix_ffmpeg_commands_TIMESTAMP.sh    (corrected FFmpeg commands)
#    - diagnose_duplex_TIMESTAMP.sh        (half-duplex investigation tool)
#
#  Usage:
#    sudo ./streaming_health_check.sh                   # terminal only
#    sudo ./streaming_health_check.sh --html            # terminal + all outputs
#    sudo ./streaming_health_check.sh --html --seconds 10
# =============================================================================
set -uo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
DURATION=5
HTML_MODE=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --html)        HTML_MODE=true ;;
    --seconds)     shift; DURATION="${1:-5}" ;;
    --seconds=*)   DURATION="${1#*=}" ;;
    [0-9]*)        DURATION="$1" ;;
  esac
  shift
done

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
REPORT_FILE="${SCRIPT_DIR}/streaming_report_${TIMESTAMP}.html"
FIX_SYS_FILE="${SCRIPT_DIR}/fix_system_${TIMESTAMP}.sh"
FIX_FFMPEG_FILE="${SCRIPT_DIR}/fix_ffmpeg_commands_${TIMESTAMP}.sh"
DIAG_DUPLEX_FILE="${SCRIPT_DIR}/diagnose_duplex_${TIMESTAMP}.sh"

# ── Terminal colours ──────────────────────────────────────────────────────────
RED=$'\e[31m'; GREEN=$'\e[32m'; YELLOW=$'\e[33m'
CYAN=$'\e[36m'; BOLD=$'\e[1m'; DIM=$'\e[2m'; RESET=$'\e[0m'

# ── Result storage ────────────────────────────────────────────────────────────
declare -a ALL_CHECKS=()
declare -a FFMPEG_PROCS=()
declare -a FIX_COMMANDS=()
declare -a SYSCTL_FIXES=()
declare -a PMSET_FIXES=()
declare -a PF_FIXES=()
declare -a ROUTE_FIXES=()

# ── Counters & discovered values ──────────────────────────────────────────────
ISSUES=0; WARNINGS=0; PASSES=0
SENDER_PID=""; SENDER_CMD=""
MCAST_GROUP="239.1.1.1"; MCAST_PORT="1234"
OUTBOUND_IFACE="en0"
REQUESTED_VBR=0; REQUESTED_ABR=0; REQUESTED_TOTAL=0
ACTUAL_KBPS=0; RATIO=0
LINK_SPEED="unknown"; DUPLEX="unknown"
LEAK_OK=false; LO_PKTS=0; IF_PKTS=0
LO_MBPS="0.00"; IF_MBPS="0.00"
VBR_RAW=""; ABR_RAW=""; VCODEC=""; ACODEC=""
PRESET=""; TUNE=""; PKT_SIZE_VAL=""
LOCALADDR=""; TTL_VAL=""; INPUT_SRC=""
MAXRATE_RAW=""; BUFSIZE_RAW=""
SENDER_COUNT=0; YOUTUBE_COUNT=0; WEBRTC_COUNT=0; UNKNOWN_COUNT=0
IP_ADDR=""; MTU="1500"
FREE_MB=0; SWAP_USED="0M"; LOAD1="0"; CPU_COUNT=4
UDP_DROPPED=0
YOUTUBE_CMD=""; WEBRTC_CMD=""
RXE_VAL=0; TXE_VAL=0; COL_VAL=0

# =============================================================================
# ── TERMINAL HELPERS ──────────────────────────────────────────────────────────
# =============================================================================
t_banner() {
  clear
  echo
  echo "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
  echo "${BOLD}${CYAN}║        Streaming Appliance Health Check   v5.0               ║${RESET}"
  echo "${BOLD}${CYAN}║        $(date)                  ║${RESET}"
  $HTML_MODE \
    && echo "${BOLD}${CYAN}║        Mode: Terminal + HTML + Fix Scripts                   ║${RESET}" \
    || echo "${BOLD}${CYAN}║        Mode: Terminal only                                   ║${RESET}"
  echo "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
  echo
}

t_section() {
  echo
  echo "${BOLD}${CYAN}┌──────────────────────────────────────────────────────────────┐${RESET}"
  printf "${BOLD}${CYAN}│  %-61s│${RESET}\n" "$1"
  echo "${BOLD}${CYAN}└──────────────────────────────────────────────────────────────┘${RESET}"
  echo
}

t_ok()   { echo "  ${GREEN}✅  $*${RESET}"; }
t_warn() { echo "  ${YELLOW}⚠️   $*${RESET}"; }
t_fail() { echo "  ${RED}🚨  $*${RESET}"; }
t_info() { echo "  ${DIM}    $*${RESET}"; }
t_note() { echo "  ${CYAN}    $*${RESET}"; }
t_div()  { echo "  ${DIM}──────────────────────────────────────────────────────${RESET}"; }
t_blank(){ echo; }

# =============================================================================
# ── CHECK ENGINE ──────────────────────────────────────────────────────────────
# =============================================================================
# add_check STATUS SECTION TITLE VALUE EXPLANATION FIX
add_check() {
  local status="$1" section="$2" title="$3" value="$4" expl="$5" fix="${6:-}"
  ALL_CHECKS+=("${status}|||${section}|||${title}|||${value}|||${expl}|||${fix}")
  case "$status" in
    ok)   PASSES=$((PASSES+1));     t_ok   "${title}: ${value}" ;;
    warn) WARNINGS=$((WARNINGS+1)); t_warn "${title}: ${value}" ;;
    fail) ISSUES=$((ISSUES+1));     t_fail "${title}: ${value}" ;;
    info) t_note "${title}: ${value}" ;;
  esac
  [ -n "$fix" ] && FIX_COMMANDS+=("$fix")
}

# =============================================================================
# ── UTILITIES ─────────────────────────────────────────────────────────────────
# =============================================================================
need()       { command -v "$1" >/dev/null 2>&1 || { t_fail "Missing: $1"; exit 1; }; }
pmset_val()  { pmset -g 2>/dev/null | awk -v k="$1" '$1==k{print $2;exit}'; }
sysctl_val() { sysctl -n "$1" 2>/dev/null || echo "0"; }
iface_bytes(){ netstat -ibn -I "$1" 2>/dev/null | awk 'NR>1{rx+=$7;tx+=$10}END{print rx+0,tx+0}'; }

parse_bitrate() {
  local v="$1"
  if   echo "$v" | grep -qiE '^[0-9]+[kK]$'; then echo "$v" | tr -d 'kKmM'
  elif echo "$v" | grep -qiE '^[0-9]+[mM]$'; then echo $(( $(echo "$v"|tr -d 'mM') * 1000 ))
  else echo "$v" | tr -d 'kKmM'; fi
}

html_esc() { echo "$*" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# =============================================================================
# ── SECTION 1: PRE-FLIGHT ─────────────────────────────────────────────────────
# =============================================================================
t_banner
t_section "1 of 9 — Pre-flight"

for tool in tcpdump netstat ifconfig awk grep ps lsof pmset sysctl pfctl route bc; do
  need "$tool"
done
add_check ok preflight "Required tools" "all present" "All diagnostic tools are available." ""

if [ "$(id -u)" -ne 0 ]; then
  add_check fail preflight "Root access" "NOT root" \
    "Requires sudo to read firewall rules, run tcpdump, and access system stats." \
    "Re-run: sudo $0"
  exit 1
fi
add_check ok preflight "Root access" "running as root" "Has privileges for all checks." ""

# =============================================================================
# ── SECTION 2: FFMPEG DETECTION ──────────────────────────────────────────────
# =============================================================================
t_section "2 of 9 — FFmpeg Process Detection"

FFMPEG_PIDS=$(pgrep ffmpeg 2>/dev/null || true)

if [ -z "$FFMPEG_PIDS" ]; then
  add_check fail ffmpeg "FFmpeg processes" "none found" \
    "No FFmpeg processes running. Most checks will be inconclusive." ""
else
  PID_COUNT=$(echo "$FFMPEG_PIDS" | wc -l | tr -d ' ')
  add_check ok ffmpeg "FFmpeg processes" "$PID_COUNT found" \
    "FFmpeg is running. Classifying each process." ""

  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    CMD=$(ps -p "$pid" -o args= 2>/dev/null || true)
    [ -z "$CMD" ] && continue
    CPU=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ' || echo "?")
    MEM=$(ps -p "$pid" -o rss=  2>/dev/null | awk '{printf "%.1f MB",$1/1024}' || echo "?")
    START=$(ps -p "$pid" -o lstart= 2>/dev/null || echo "?")
    FDS=$(lsof -p "$pid" 2>/dev/null | wc -l | tr -d ' ' || echo "?")
    ROLE="unknown"
    if echo "$CMD" | grep -qE "udp://(23[0-9]|22[4-9])\.[0-9.]+:[0-9]+"; then
      ROLE="sender"; SENDER_COUNT=$((SENDER_COUNT+1))
      SENDER_PID="$pid"; SENDER_CMD="$CMD"
    elif echo "$CMD" | grep -qi "rtmp"; then
      ROLE="youtube"; YOUTUBE_COUNT=$((YOUTUBE_COUNT+1)); YOUTUBE_CMD="$CMD"
    elif echo "$CMD" | grep -q "udp://127\.0\.0\.1"; then
      ROLE="webrtc"; WEBRTC_COUNT=$((WEBRTC_COUNT+1)); WEBRTC_CMD="$CMD"
    else
      UNKNOWN_COUNT=$((UNKNOWN_COUNT+1))
    fi
    FFMPEG_PROCS+=("${pid}|||${ROLE}|||${CPU}|||${MEM}|||${FDS}|||${START}|||${CMD}")
    case "$ROLE" in
      sender)  t_ok   "PID $pid [SENDER→MULTICAST] CPU:${CPU}% MEM:${MEM}" ;;
      youtube) t_ok   "PID $pid [RECEIVER→YOUTUBE]  CPU:${CPU}% MEM:${MEM}" ;;
      webrtc)  t_ok   "PID $pid [RECEIVER→WEBRTC]   CPU:${CPU}% MEM:${MEM}" ;;
      *)       t_warn "PID $pid [UNKNOWN]            CPU:${CPU}% MEM:${MEM}" ;;
    esac
    t_info "  Started: $START"
    t_blank
  done <<< "$FFMPEG_PIDS"
fi

[ "$SENDER_COUNT"  -eq 0 ] && add_check fail   ffmpeg "Sender process"   "not found" "No multicast sender detected." ""
[ "$YOUTUBE_COUNT" -eq 0 ] && add_check warn   ffmpeg "YouTube receiver" "not found" "No RTMP receiver process detected." ""
[ "$WEBRTC_COUNT"  -eq 0 ] && add_check warn   ffmpeg "WebRTC receiver"  "not found" "No WebRTC receiver process detected." ""
[ "$UNKNOWN_COUNT" -gt 0 ] && add_check warn   ffmpeg "Unclassified"     "$UNKNOWN_COUNT process(es)" "Could not classify these processes." ""

ZOMBIES=$(ps aux 2>/dev/null | awk '/ffmpeg/&&/defunct/{print $2}' || true)
if [ -n "$ZOMBIES" ]; then
  add_check fail ffmpeg "Zombie processes" "PIDs: $ZOMBIES" \
    "Dead processes not cleaned up. Consume PIDs, interfere with restarts." \
    "sudo pkill -9 ffmpeg"
else
  add_check ok ffmpeg "Zombie processes" "none" "No defunct FFmpeg processes." ""
fi

# =============================================================================
# ── SECTION 3: SENDER ANALYSIS ───────────────────────────────────────────────
# =============================================================================
t_section "3 of 9 — Sender Command Analysis"

if [ -z "$SENDER_PID" ]; then
  t_warn "No sender found — skipping"
else
  t_note "Analysing PID $SENDER_PID..."; t_blank

  VBR_RAW=$(echo "$SENDER_CMD" | grep -oE '\-b:v [^ ]+' | awk '{print $2}' || true)
  ABR_RAW=$(echo "$SENDER_CMD" | grep -oE '\-b:a [^ ]+' | awk '{print $2}' || true)

  if [ -n "$VBR_RAW" ]; then
    REQUESTED_VBR=$(parse_bitrate "$VBR_RAW")
    add_check ok sender "Video bitrate" "${VBR_RAW} (${REQUESTED_VBR} kbit/s)" \
      "Explicit video bitrate set. Essential for predictable stream behaviour." ""
  else
    add_check warn sender "Video bitrate" "not set" \
      "No -b:v set. Encoder will choose freely causing unpredictable bitrate swings." \
      "Add -b:v 4000k to sender"
    VBR_RAW="4000k"; REQUESTED_VBR=4000
  fi

  if [ -n "$ABR_RAW" ]; then
    REQUESTED_ABR=$(parse_bitrate "$ABR_RAW")
    add_check ok sender "Audio bitrate" "${ABR_RAW} (${REQUESTED_ABR} kbit/s)" \
      "Explicit audio bitrate set." ""
  else
    add_check warn sender "Audio bitrate" "not set" \
      "No -b:a set. Add explicit audio bitrate." \
      "Add -b:a 128k to sender"
    ABR_RAW="128k"; REQUESTED_ABR=128
  fi

  REQUESTED_TOTAL=$((REQUESTED_VBR + REQUESTED_ABR))
  REQUESTED_MBPS=$(echo "scale=2; $REQUESTED_TOTAL/1000" | bc 2>/dev/null || echo "?")
  add_check info sender "Total requested bitrate" "${REQUESTED_TOTAL} kbit/s (${REQUESTED_MBPS} Mbit/s)" \
    "Combined video + audio target." ""

  t_div; t_blank

  VCODEC=$(echo "$SENDER_CMD"  | grep -oE '\-c:v [^ ]+' | awk '{print $2}' || true)
  ACODEC=$(echo "$SENDER_CMD"  | grep -oE '\-c:a [^ ]+' | awk '{print $2}' || true)
  PRESET=$(echo "$SENDER_CMD"  | grep -oE '\-preset [^ ]+' | awk '{print $2}' || true)
  TUNE=$(echo "$SENDER_CMD"    | grep -oE '\-tune [^ ]+'   | awk '{print $2}' || true)
  MAXRATE_RAW=$(echo "$SENDER_CMD" | grep -oE '\-maxrate [^ ]+' | awk '{print $2}' || true)
  BUFSIZE_RAW=$(echo "$SENDER_CMD" | grep -oE '\-bufsize [^ ]+' | awk '{print $2}' || true)
  INPUT_SRC=$(echo "$SENDER_CMD"   | grep -oE '\-i [^ ]+' | head -1 | awk '{print $2}' || true)

  [ -n "$VCODEC" ] && add_check info sender "Video codec" "$VCODEC" "Detected encoder." ""
  [ -n "$ACODEC" ] && add_check info sender "Audio codec" "$ACODEC" "Detected audio encoder." ""

  if [ -n "$PRESET" ]; then
    case "$PRESET" in
      ultrafast|superfast|veryfast)
        add_check ok sender "Preset" "$PRESET" "Correct for live streaming — low CPU, low latency." "" ;;
      fast|medium)
        add_check warn sender "Preset" "$PRESET" \
          "Too slow for live streaming. Adds latency and burns CPU." "Change -preset to veryfast" ;;
      slow|slower|veryslow|placebo)
        add_check fail sender "Preset" "$PRESET" \
          "Far too slow. Will fall behind real-time causing growing latency and dropped frames." \
          "Change -preset to veryfast immediately" ;;
    esac
  else
    add_check warn sender "Preset" "not set (default: medium)" \
      "libx264 defaults to medium — too slow for live streaming." "Add -preset veryfast"
  fi

  if [ -n "$TUNE" ]; then
    if [ "$TUNE" = "zerolatency" ]; then
      add_check ok sender "Tune" "zerolatency" \
        "Disables b-frames and lookahead. Essential for live streaming." ""
    else
      add_check warn sender "Tune" "$TUNE" \
        "Not optimised for live. zerolatency removes b-frame buffering delays." \
        "Change -tune to zerolatency"
    fi
  else
    add_check warn sender "Tune" "not set" \
      "Add -tune zerolatency to reduce end-to-end latency." "Add -tune zerolatency"
  fi

  [ -z "$MAXRATE_RAW" ] && add_check warn sender "Max rate" "not set" \
    "Without -maxrate encoder can burst well above target, overflowing downstream buffers." \
    "Add -maxrate ${VBR_RAW} -bufsize $(echo "scale=0;$(parse_bitrate $VBR_RAW)*2" | bc 2>/dev/null || echo 8000)k"

  t_div; t_blank

  MCAST_URL=$(echo "$SENDER_CMD" | grep -oE 'udp://(23[0-9]|22[4-9])\.[0-9.]+:[0-9]+' | head -1 || true)
  if [ -n "$MCAST_URL" ]; then
    MCAST_GROUP=$(echo "$MCAST_URL" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    MCAST_PORT=$(echo  "$MCAST_URL" | grep -oE ':[0-9]+$' | tr -d ':')
    add_check ok sender "Multicast output" "$MCAST_GROUP:$MCAST_PORT" \
      "Group and port the sender writes to. All receivers must subscribe here." ""
  fi

  LOCALADDR=$(echo "$SENDER_CMD" | grep -oE 'localaddr=[^& "]+' | cut -d= -f2 || true)
  if [ "$LOCALADDR" = "127.0.0.1" ]; then
    add_check ok sender "localaddr" "127.0.0.1" \
      "Sender bound to loopback. First defence against multicast leaking to physical NIC." ""
  elif [ -n "$LOCALADDR" ]; then
    add_check fail sender "localaddr" "$LOCALADDR (should be 127.0.0.1)" \
      "Non-loopback localaddr — multicast WILL flood the physical network." \
      "Change localaddr=127.0.0.1 in sender UDP URL"
  else
    add_check fail sender "localaddr" "NOT SET" \
      "No localaddr. macOS will route multicast via the physical NIC by default — flooding your network." \
      "Add localaddr=127.0.0.1 to sender UDP URL"
  fi

  TTL_VAL=$(echo "$SENDER_CMD" | grep -oE '\bttl=[0-9]+' | cut -d= -f2 || true)
  if [ "$TTL_VAL" = "0" ]; then
    add_check ok sender "TTL" "0" \
      "Packets cannot route beyond this host. Belt-and-suspenders against escape." ""
  elif [ -n "$TTL_VAL" ]; then
    add_check fail sender "TTL" "$TTL_VAL (should be 0)" \
      "TTL > 0 allows multicast packets to be forwarded by routers onto your network." \
      "Change ttl=0 in sender UDP URL"
  else
    add_check fail sender "TTL" "NOT SET" \
      "Default TTL is 1 — allows subnet propagation. Must be explicitly set to 0." \
      "Add ttl=0 to sender UDP URL"
  fi

  PKT_SIZE_VAL=$(echo "$SENDER_CMD" | grep -oE 'pkt_size=[0-9]+' | cut -d= -f2 || true)
  if [ -n "$PKT_SIZE_VAL" ]; then
    if [ "$PKT_SIZE_VAL" -eq 1316 ]; then
      add_check ok sender "pkt_size" "1316" "Optimal — 7×188 byte MPEG-TS packets. No fragmentation risk." ""
    elif [ "$PKT_SIZE_VAL" -gt 1472 ]; then
      add_check warn sender "pkt_size" "$PKT_SIZE_VAL (may fragment)" \
        "Above 1472 bytes risks IP fragmentation. Fragmented packets increase loss probability." \
        "Change pkt_size=1316"
    else
      add_check info sender "pkt_size" "$PKT_SIZE_VAL" "Non-default. 1316 is recommended." ""
    fi
  else
    add_check warn sender "pkt_size" "not set" \
      "Default may not be optimal for your path. 1316 is the standard for MPEG-TS over UDP." \
      "Add pkt_size=1316 to sender UDP URL"
  fi

  [ -n "$INPUT_SRC" ] && add_check info sender "Input source" "$INPUT_SRC" "Detected input device." ""
fi

# =============================================================================
# ── SECTION 4: NETWORK INTERFACE ─────────────────────────────────────────────
# =============================================================================
t_section "4 of 9 — Network Interface Health"

OUTBOUND_IFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' || echo "en0")
[ -z "$OUTBOUND_IFACE" ] && OUTBOUND_IFACE="en0"
add_check info network "Outbound interface" "$OUTBOUND_IFACE" "Detected via default route." ""

IFACE_INFO=$(ifconfig "$OUTBOUND_IFACE" 2>/dev/null || true)

if [ -z "$IFACE_INFO" ]; then
  add_check fail network "Interface" "NOT FOUND: $OUTBOUND_IFACE" "Interface missing." ""
else
  if echo "$IFACE_INFO" | grep -q "UP"; then
    add_check ok   network "UP flag"   "UP"         "Interface administratively up." ""
  else
    add_check fail network "UP flag"   "DOWN"       "Interface is down. No traffic possible." \
      "sudo ifconfig $OUTBOUND_IFACE up"
  fi
  if echo "$IFACE_INFO" | grep -q "RUNNING"; then
    add_check ok   network "RUNNING"   "yes"        "Active physical link." ""
  else
    add_check fail network "RUNNING"   "no"         "No link — check cable or switch port." ""
  fi
  if echo "$IFACE_INFO" | grep -q "MULTICAST"; then
    add_check ok   network "MULTICAST" "supported"  "Interface supports multicast." ""
  else
    add_check warn network "MULTICAST" "not set"    "Interface may not support multicast." \
      "sudo ifconfig $OUTBOUND_IFACE multicast"
  fi
  IP_ADDR=$(echo "$IFACE_INFO" | awk '/inet /{print $2}' | head -1 || true)
  if [ -n "$IP_ADDR" ]; then
    add_check ok   network "IP address" "$IP_ADDR"  "Valid IP assigned." ""
  else
    add_check fail network "IP address" "none"      "No IP. Cannot reach YouTube/WebRTC servers." ""
  fi
  MTU=$(echo "$IFACE_INFO" | grep -oE 'mtu [0-9]+' | awk '{print $2}' || echo "?")
  if [ "$MTU" = "1500" ]; then
    add_check ok   network "MTU" "1500" "Standard MTU. No fragmentation risk." ""
  else
    add_check info network "MTU" "$MTU" "Non-standard. Verify full path supports this." ""
  fi
fi

t_div; t_blank

MEDIA_INFO=$(ifconfig "$OUTBOUND_IFACE" 2>/dev/null | grep -iE "media:" || true)
if [ -n "$MEDIA_INFO" ]; then
  t_info "Media: $MEDIA_INFO"; t_blank
  if echo "$MEDIA_INFO" | grep -qi "half"; then
    DUPLEX="half"
    add_check fail network "Duplex" "HALF DUPLEX DETECTED" \
      "Half duplex means the NIC can only send OR receive at one time — never both. Every incoming ACK from YouTube interrupts your outgoing video stream causing stuttering, retransmits, and rising latency. Root cause is outside this machine: bad cable, old switch port, or failed autonegotiation. Run the generated diagnose_duplex script for full investigation steps." \
      "# See diagnose_duplex_${TIMESTAMP}.sh for full investigation"
  elif echo "$MEDIA_INFO" | grep -qi "full"; then
    DUPLEX="full"
    add_check ok network "Duplex" "full duplex" \
      "Simultaneous send and receive. Essential for streaming." ""
  else
    DUPLEX="unknown"
    add_check warn network "Duplex" "could not confirm" \
      "Duplex mode unclear. Run diagnose_duplex script to investigate." \
      "# See diagnose_duplex_${TIMESTAMP}.sh"
  fi
  SPEED=$(echo "$MEDIA_INFO" | grep -oE '[0-9]+base[^ ,>]+' | head -1 || true)
  if [ -n "$SPEED" ]; then
    LINK_SPEED="$SPEED"
    if   echo "$SPEED" | grep -q "10G";  then add_check ok   network "Link speed" "$SPEED" "10G — excellent." ""
    elif echo "$SPEED" | grep -q "1000"; then add_check ok   network "Link speed" "$SPEED" "Gigabit — good for streaming." ""
    elif echo "$SPEED" | grep -q "100";  then add_check warn network "Link speed" "$SPEED" "100Mbps — workable but limited headroom." ""
    else                                       add_check fail network "Link speed" "$SPEED" "Insufficient for video streaming." ""
    fi
  fi
else
  add_check warn network "Link / duplex" "could not detect" \
    "May be Wi-Fi or virtual interface. Wi-Fi is not suitable for production streaming." ""
  if system_profiler SPAirPortDataType 2>/dev/null | grep -q "$OUTBOUND_IFACE"; then
    add_check fail network "Interface type" "Wi-Fi" \
      "Wi-Fi floods all connected devices with multicast. Use wired Ethernet." ""
  fi
fi

t_div; t_blank

RXE_VAL=$(netstat -ibn -I "$OUTBOUND_IFACE" 2>/dev/null | awk 'NR>1{e+=$6}END{print e+0}' || echo 0)
TXE_VAL=$(netstat -ibn -I "$OUTBOUND_IFACE" 2>/dev/null | awk 'NR>1{e+=$9}END{print e+0}' || echo 0)
COL_VAL=$(netstat -ibn -I "$OUTBOUND_IFACE" 2>/dev/null | awk 'NR>1{c+=$11}END{print c+0}' || echo 0)

if [ "${RXE_VAL:-0}" -eq 0 ]; then
  add_check ok   network "RX errors"   "0"          "No receive errors." ""
else
  add_check fail network "RX errors"   "$RXE_VAL"   "Bad cable, faulty NIC, or switch port issue." \
    "Replace cable and test different switch port"
fi
if [ "${TXE_VAL:-0}" -eq 0 ]; then
  add_check ok   network "TX errors"   "0"          "No transmit errors." ""
else
  add_check fail network "TX errors"   "$TXE_VAL"   "NIC failing to transmit. Check cable and driver." ""
fi
if [ "${COL_VAL:-0}" -eq 0 ]; then
  add_check ok   network "Collisions"  "0"          "Zero collisions confirms full-duplex." ""
else
  add_check fail network "Collisions"  "$COL_VAL"   \
    "Collisions are IMPOSSIBLE on full-duplex. This is definitive proof of half-duplex or a faulty cable. Run diagnose_duplex script." \
    "# See diagnose_duplex_${TIMESTAMP}.sh for root cause steps"
fi

# =============================================================================
# ── SECTION 5: MULTICAST ROUTING ─────────────────────────────────────────────
# =============================================================================
t_section "5 of 9 — Multicast Routing"

ROUTE_TABLE=$(netstat -rn 2>/dev/null | awk '/^22[4-9]\.|^23[0-9]\./{print}' || true)

if [ -n "$ROUTE_TABLE" ]; then
  t_info "Route entries:"; echo "${DIM}$(echo "$ROUTE_TABLE" | sed 's/^/    /')${RESET}"; t_blank
  if echo "$ROUTE_TABLE" | awk '{print $NF}' | grep -q "^lo0$"; then
    add_check ok   routing "Multicast → lo0"           "found"          "Multicast routes to loopback. Correct." ""
  else
    add_check warn routing "Multicast → lo0"           "not found"      "No loopback route. macOS may route to physical NIC." \
      "sudo route -n add -net 224.0.0.0/4 127.0.0.1"
  fi
  if echo "$ROUTE_TABLE" | awk '{print $NF}' | grep -qE "^${OUTBOUND_IFACE}$"; then
    add_check fail routing "Multicast → $OUTBOUND_IFACE" "FOUND — leak" "Route points to physical NIC. Multicast WILL flood network." \
      "sudo route delete -net 224.0.0.0/4 && sudo route -n add -net 224.0.0.0/4 127.0.0.1"
    ROUTE_FIXES+=("sudo route delete -net 224.0.0.0/4")
    ROUTE_FIXES+=("sudo route -n add -net 224.0.0.0/4 127.0.0.1")
  else
    add_check ok   routing "Multicast → $OUTBOUND_IFACE" "none"          "No leak route on physical interface." ""
  fi
else
  add_check warn routing "Multicast routes" "none explicit" \
    "No multicast routes. macOS defaults to physical interface. PF rules are critical." \
    "sudo route -n add -net 224.0.0.0/4 127.0.0.1"
  ROUTE_FIXES+=("sudo route -n add -net 224.0.0.0/4 127.0.0.1")
fi

MEMBERSHIPS=$(netstat -gn 2>/dev/null || true)
if echo "$MEMBERSHIPS" | grep -q "$MCAST_GROUP"; then
  JOINED_ON=$(echo "$MEMBERSHIPS" | grep "$MCAST_GROUP" | awk '{print $1}' | sort -u | tr '\n' ' ')
  add_check info routing "Group $MCAST_GROUP joined on" "$JOINED_ON" "Active multicast group memberships." ""
  if echo "$JOINED_ON" | grep -qE "(^| )${OUTBOUND_IFACE}( |$)"; then
    add_check fail routing "Group on $OUTBOUND_IFACE" "YES — leak path" \
      "Group joined on physical interface creates active leak path." \
      "Fix sender localaddr + apply PF rules"
  else
    add_check ok routing "Group on $OUTBOUND_IFACE" "no" "Group not on physical interface. Correct." ""
  fi
fi

# =============================================================================
# ── SECTION 6: PF FIREWALL ───────────────────────────────────────────────────
# =============================================================================
t_section "6 of 9 — PF Firewall"

PF_STATUS=$(pfctl -si 2>/dev/null | awk '/^Status:/{print $2}' || echo "unknown")
if [ "$PF_STATUS" = "Enabled" ]; then
  add_check ok   firewall "PF firewall" "Enabled" "Packet filter active." ""
else
  add_check fail firewall "PF firewall" "NOT ENABLED" \
    "PF is the hard block preventing multicast escape. Without it only the FFmpeg localaddr hint protects you — which macOS may ignore." \
    "sudo pfctl -e"
  PF_FIXES+=("sudo pfctl -e")
fi

PF_RULES=$(pfctl -sr 2>/dev/null || true)

if echo "$PF_RULES" | grep -q "block.*out.*${OUTBOUND_IFACE}.*224\.0\.0\.0"; then
  add_check ok   firewall "Block OUT ($OUTBOUND_IFACE)" "active" \
    "Outbound multicast hard-blocked at kernel level." ""
else
  add_check fail firewall "Block OUT ($OUTBOUND_IFACE)" "MISSING" \
    "No outbound block. Any multicast reaching $OUTBOUND_IFACE will flood the network." \
    "sudo sh -c 'echo \"block out quick on $OUTBOUND_IFACE proto udp to 224.0.0.0/4\" >> /etc/pf.conf'"
  PF_FIXES+=("sudo sh -c 'echo \"block out quick on $OUTBOUND_IFACE proto udp to 224.0.0.0/4\" >> /etc/pf.conf'")
fi

if echo "$PF_RULES" | grep -q "block.*in.*${OUTBOUND_IFACE}.*224\.0\.0\.0"; then
  add_check ok   firewall "Block IN ($OUTBOUND_IFACE)"  "active" \
    "Inbound multicast blocked." ""
else
  add_check fail firewall "Block IN ($OUTBOUND_IFACE)"  "MISSING" \
    "No inbound block. External multicast can enter and interact with internal bus." \
    "sudo sh -c 'echo \"block in  quick on $OUTBOUND_IFACE proto udp to 224.0.0.0/4\" >> /etc/pf.conf'"
  PF_FIXES+=("sudo sh -c 'echo \"block in  quick on $OUTBOUND_IFACE proto udp to 224.0.0.0/4\" >> /etc/pf.conf'")
fi

[ ${#PF_FIXES[@]} -gt 0 ] && PF_FIXES+=("sudo pfctl -f /etc/pf.conf && sudo pfctl -e")

# =============================================================================
# ── SECTION 7: KERNEL PARAMETERS ─────────────────────────────────────────────
# =============================================================================
t_section "7 of 9 — Kernel Parameters & UDP Health"

check_sysctl_ge() {
  local key="$1" want="$2" label="$3" expl="$4"
  local val; val=$(sysctl_val "$key")
  if [ "$val" -ge "$want" ] 2>/dev/null; then
    add_check ok kernel "$key" "$val" "$expl" ""
  else
    add_check fail kernel "$key" "$val (need >= $want)" "$expl" \
      "sudo sysctl -w $key=$want"
    SYSCTL_FIXES+=("sudo sysctl -w $key=$want   # $label")
  fi
}

check_sysctl_ge "net.inet.udp.maxdgram"  65535   "Max UDP datagram" \
  "Max size of a UDP datagram. If too small, large packets are silently truncated — corrupting MPEG-TS frames."
check_sysctl_ge "net.inet.udp.recvspace" 1048576 "UDP receive buffer" \
  "Per-socket receive buffer. Too small means the kernel drops packets when receivers can't read fast enough. Every drop corrupts an MPEG-TS frame."
check_sysctl_ge "net.inet.udp.sendspace" 1048576 "UDP send buffer" \
  "Per-socket send buffer. Too small stalls the FFmpeg encoder when the kernel can't schedule packets fast enough."
check_sysctl_ge "kern.ipc.maxsockbuf"    8388608 "Max socket buffer" \
  "System ceiling for all socket buffers. recvspace/sendspace silently cap at this value even if set higher."
check_sysctl_ge "kern.maxfiles"          65536   "Max open files" \
  "System-wide file descriptor limit. FFmpeg opens many fds per stream. Exhaustion causes 'too many open files' failures."
check_sysctl_ge "kern.maxfilesperproc"   65536   "Max files per process" \
  "Per-process fd limit. A single FFmpeg with many filters and outputs can hit this."

DELAYED_ACK=$(sysctl_val "net.inet.tcp.delayed_ack")
if [ "$DELAYED_ACK" = "0" ]; then
  add_check ok kernel "net.inet.tcp.delayed_ack" "0 (disabled)" \
    "TCP delayed ACK off. ACKs sent immediately — reduces RTMP/WebRTC control latency." ""
else
  add_check warn kernel "net.inet.tcp.delayed_ack" "$DELAYED_ACK (should be 0)" \
    "Delayed ACK adds up to 200ms latency to every TCP ACK. Over time causes YouTube RTMP to throttle back." \
    "sudo sysctl -w net.inet.tcp.delayed_ack=0"
  SYSCTL_FIXES+=("sudo sysctl -w net.inet.tcp.delayed_ack=0   # Disable TCP delayed ACK")
fi

t_div; t_blank

UDP_DROPPED=$(netstat -su 2>/dev/null \
  | awk '/dropped|drop/{gsub(/[^0-9]/,"",$1);if($1+0>0){print $1+0;exit}}' || echo "0")
if [ "${UDP_DROPPED:-0}" -eq 0 ]; then
  add_check ok   kernel "UDP dropped" "0" "Kernel not dropping packets. Buffers healthy." ""
else
  add_check fail kernel "UDP dropped" "$UDP_DROPPED packets" \
    "Kernel dropping UDP — arrives faster than receivers read, or buffers too small. Every drop = corrupted frame." \
    "sudo sysctl -w net.inet.udp.recvspace=4194304 && sudo sysctl -w kern.ipc.maxsockbuf=16777216"
  SYSCTL_FIXES+=("sudo sysctl -w net.inet.udp.recvspace=4194304   # Emergency buffer increase")
  SYSCTL_FIXES+=("sudo sysctl -w kern.ipc.maxsockbuf=16777216     # Increase socket buffer ceiling")
fi

# =============================================================================
# ── SECTION 8: RESOURCES & POWER ─────────────────────────────────────────────
# =============================================================================
t_section "8 of 9 — System Resources & Power Management"

LOAD=$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2,$3,$4}' || echo "? ? ?")
LOAD1=$(echo "$LOAD" | awk '{print $1}')
CPU_COUNT=$(sysctl -n hw.logicalcpu 2>/dev/null || echo "4")
LOAD_INT=$(echo "$LOAD1" | cut -d. -f1)
add_check info resources "CPU cores" "$CPU_COUNT" "Logical CPU cores available." ""
if   [ "${LOAD_INT:-0}" -lt "$CPU_COUNT" ]          2>/dev/null; then
  add_check ok   resources "CPU load" "$LOAD" "Load below core count. Healthy headroom." ""
elif [ "${LOAD_INT:-0}" -lt $((CPU_COUNT*2)) ]      2>/dev/null; then
  add_check warn resources "CPU load" "$LOAD" "Elevated. Monitor — may start dropping frames." ""
else
  add_check fail resources "CPU load" "$LOAD" \
    "Severely overloaded. Encoder will drop frames and stream will degrade." \
    "Close background processes immediately"
fi

VM_STAT=$(vm_stat 2>/dev/null || true)
PAGE_SIZE=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
FREE_PAGES=$(echo "$VM_STAT" | awk '/Pages free/{gsub(/[^0-9]/,"",$NF); print $NF+0; exit}')
FREE_PAGES="${FREE_PAGES:-0}"
COMP_PAGES=$(echo "$VM_STAT" | awk '/compressor/{gsub(/[^0-9]/,"",$NF); print $NF+0; exit}')
COMP_PAGES="${COMP_PAGES:-0}"
FREE_MB=$(( (FREE_PAGES * PAGE_SIZE) / 1048576 ))
COMP_MB=$(( (COMP_PAGES * PAGE_SIZE) / 1048576 ))
add_check info resources "Memory free"       "${FREE_MB} MB"  "Unallocated RAM." ""
add_check info resources "Memory compressed" "${COMP_MB} MB"  "Compressed pages — high = memory pressure." ""
if   [ "$FREE_MB" -gt 500 ]; then add_check ok   resources "Memory health" "${FREE_MB} MB free"          "Healthy." ""
elif [ "$FREE_MB" -gt 200 ]; then add_check warn resources "Memory health" "${FREE_MB} MB free (low)"    "Getting low. Risk of swap." ""
else                               add_check fail resources "Memory health" "${FREE_MB} MB free (critical)" \
  "Swap likely. Disk latency will stall encoder — expect dropped frames and stream failure." \
  "Close non-essential applications"
fi

SWAP=$(sysctl -n vm.swapusage 2>/dev/null | grep -oE 'used = [0-9.]+[MG]' | awk '{print $3}' || echo "0.00M")
if echo "$SWAP" | grep -qE "^0\.0+M$|^0M$"; then
  add_check ok   resources "Swap" "0 — none"       "All memory in fast RAM." ""
else
  add_check warn resources "Swap" "$SWAP in use"   "Swap causes latency spikes. Close apps." ""
fi

t_div; t_blank
t_note "Power management..."; t_blank

check_pmset() {
  local key="$1" want="$2" label="$3" expl="$4"
  local val; val=$(pmset_val "$key")
  [ -z "$val" ] && { add_check warn power "pmset: $key" "not found" "Not in pmset output." ""; return; }
  if [ "$val" = "$want" ]; then
    add_check ok power "pmset: $key" "$val" "$expl" ""
  else
    add_check fail power "pmset: $key" "$val (should be $want)" "$expl" \
      "sudo pmset -a $key $want"
    PMSET_FIXES+=("sudo pmset -a $key $want   # $label")
  fi
}

check_pmset sleep           0 "Never sleep"         "Machine sleeping kills all streams instantly."
check_pmset displaysleep    0 "Display never sleeps" "Display sleep can trigger partial sleep states affecting network timing."
check_pmset disksleep       0 "Disk never sleeps"   "Disk sleep causes latency spikes when FFmpeg writes logs or OS pages memory."
check_pmset standby         0 "No standby"          "Standby saves RAM to disk and cuts power. Recovery takes many seconds — stream will not recover."
check_pmset powernap        0 "PowerNap off"        "PowerNap wakeups interrupt CPU scheduler and network stack — brief but real latency spikes in encoder output."
check_pmset womp            0 "Wake-on-LAN off"     "Unnecessary on appliance. Unintended magic packet could wake machine mid-configuration."
check_pmset autorestart     1 "Auto-restart"        "After a power cut the machine reboots automatically. Without this someone must press the power button."
check_pmset lowpowermode    0 "No low power mode"   "Low power throttles CPU and NIC — directly degrades encoder performance and network throughput."
check_pmset tcpkeepalive    1 "TCP keepalive on"    "Without keepalive, RTMP and WebRTC connections can be silently dropped by NAT/firewalls during quiet periods."
check_pmset networkoversleep 0 "No net over sleep"  "Prevents background network during sleep. Good hygiene on a dedicated appliance."

# =============================================================================
# ── SECTION 9: LIVE TEST ─────────────────────────────────────────────────────
# =============================================================================
t_section "9 of 9 — Live Bandwidth & Multicast Leak Test (${DURATION}s)"

t_note "Group: $MCAST_GROUP   Port: $MCAST_PORT   Iface: $OUTBOUND_IFACE"; t_blank
echo "  ${BOLD}▶  Ensure FFmpeg stream is active now.${RESET}"; t_blank

read LO_RX0 LO_TX0 < <(iface_bytes "lo0")
read IF_RX0 IF_TX0 < <(iface_bytes "$OUTBOUND_IFACE")

tcpdump -ni lo0              "udp and host $MCAST_GROUP and port $MCAST_PORT" \
  >"/tmp/mcast_lo0_${MCAST_PORT}.log" 2>&1 & PID_LO=$!
tcpdump -ni "$OUTBOUND_IFACE" "udp and host $MCAST_GROUP and port $MCAST_PORT" \
  >"/tmp/mcast_${OUTBOUND_IFACE}_${MCAST_PORT}.log" 2>&1 & PID_IF=$!

cleanup() { kill "$PID_LO" "$PID_IF" >/dev/null 2>&1 || true; }
trap cleanup EXIT

for i in $(seq "$DURATION" -1 1); do
  printf "\r  ${DIM}Sampling... %2ds remaining   ${RESET}" "$i"; sleep 1
done
printf "\r  ${GREEN}Sampling complete.                 ${RESET}\n\n"

kill "$PID_LO" "$PID_IF" >/dev/null 2>&1 || true
wait "$PID_LO" "$PID_IF" 2>/dev/null || true

read LO_RX1 LO_TX1 < <(iface_bytes "lo0")
read IF_RX1 IF_TX1 < <(iface_bytes "$OUTBOUND_IFACE")

LO_BYTES=$(( LO_TX1 - LO_TX0 ))
IF_BYTES=$(( IF_TX1 - IF_TX0 ))
LO_KBPS=$(echo "scale=1;($LO_BYTES*8)/($DURATION*1000)" | bc 2>/dev/null || echo "0")
IF_KBPS=$(echo "scale=1;($IF_BYTES*8)/($DURATION*1000)" | bc 2>/dev/null || echo "0")
LO_MBPS=$(echo "scale=2;$LO_KBPS/1000"                  | bc 2>/dev/null || echo "0.00")
IF_MBPS=$(echo "scale=2;$IF_KBPS/1000"                  | bc 2>/dev/null || echo "0.00")
LO_PKTS=$(grep -cE '^[0-9:.]+' "/tmp/mcast_lo0_${MCAST_PORT}.log"               2>/dev/null || echo "0")
IF_PKTS=$(grep -cE '^[0-9:.]+' "/tmp/mcast_${OUTBOUND_IFACE}_${MCAST_PORT}.log" 2>/dev/null || echo "0")

add_check info bandwidth "lo0 throughput"    "${LO_MBPS} Mbit/s ($LO_PKTS pkts)" "Internal multicast bus traffic." ""
add_check info bandwidth "$OUTBOUND_IFACE"   "${IF_MBPS} Mbit/s ($IF_PKTS pkts)" "Should be 0. Any value = leak." ""

if [ "$REQUESTED_TOTAL" -gt 0 ]; then
  ACTUAL_KBPS=$(echo "$LO_KBPS" | cut -d. -f1)
  RATIO=$(echo "scale=0;($ACTUAL_KBPS*100)/$REQUESTED_TOTAL" | bc 2>/dev/null || echo "0")
  if   [ "${RATIO:-0}" -ge 85 ] && [ "${RATIO:-0}" -le 115 ] 2>/dev/null; then
    add_check ok   bandwidth "Bitrate utilisation" "${RATIO}%" "Actual matches requested. Encoder healthy." ""
  elif [ "${RATIO:-0}" -lt 85 ] 2>/dev/null; then
    add_check warn bandwidth "Bitrate utilisation" "${RATIO}% (below target)" \
      "Actual below requested. CPU overload, packet loss, or stream not fully active." \
      "Check FFmpeg logs for dropped frame warnings"
  else
    add_check warn bandwidth "Bitrate utilisation" "${RATIO}% (above target)" \
      "Encoder exceeding bitrate cap. Add -maxrate and -bufsize." \
      "Add -maxrate ${VBR_RAW:-4000k} -bufsize 8000k to sender"
  fi
fi

if   [ "$LO_PKTS" -gt 0 ] && [ "$IF_PKTS" -eq 0 ]; then
  LEAK_OK=true
  add_check ok   leak "Multicast containment" "CLEAN" "All traffic on loopback only. Network safe." ""
elif [ "$IF_PKTS" -gt 0 ] && [ "$LO_PKTS" -gt 0 ]; then
  add_check fail leak "Multicast containment" "LEAK — $IF_PKTS pkts on $OUTBOUND_IFACE" \
    "Multicast escaping to physical network. Flooding local network. Fix sender localaddr+ttl and apply PF rules." \
    "Apply fix_system script immediately"
elif [ "$IF_PKTS" -gt 0 ] && [ "$LO_PKTS" -eq 0 ]; then
  add_check fail leak "Multicast containment" "CRITICAL — only on $OUTBOUND_IFACE" \
    "Sender not using loopback at all. All multicast on physical network. Fix sender immediately." \
    "Fix sender: add localaddr=127.0.0.1&ttl=0 to UDP output URL"
else
  add_check warn leak "Multicast containment" "no packets seen" \
    "Stream may not be active. Re-run with stream running." ""
fi

# =============================================================================
# ── TERMINAL SCORECARD ────────────────────────────────────────────────────────
# =============================================================================
echo
echo "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo "${BOLD}${CYAN}║                      FINAL SCORECARD                        ║${RESET}"
echo "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo
echo "  ${GREEN}Passed   : $PASSES${RESET}"
echo "  ${YELLOW}Warnings : $WARNINGS${RESET}"
echo "  ${RED}Critical : $ISSUES${RESET}"
echo

if   [ "$ISSUES" -eq 0 ] && [ "$WARNINGS" -eq 0 ] && $LEAK_OK; then
  echo "${GREEN}${BOLD}  ╔═════════════════════════════════════════════════════════════╗"
  echo            "  ║  ✅  FULLY HEALTHY — READY FOR PRODUCTION STREAMING        ║"
  echo            "  ╚═════════════════════════════════════════════════════════════╝${RESET}"
elif [ "$ISSUES" -eq 0 ]; then
  echo "${YELLOW}${BOLD}  ╔═════════════════════════════════════════════════════════════╗"
  echo            "  ║  ⚠️   MOSTLY HEALTHY — $WARNINGS warning(s) to review       ║"
  echo            "  ╚═════════════════════════════════════════════════════════════╝${RESET}"
else
  echo "${RED}${BOLD}  ╔═════════════════════════════════════════════════════════════╗"
  echo          "  ║  🚨  NOT READY — $ISSUES critical issue(s) found             ║"
  echo          "  ╚═════════════════════════════════════════════════════════════╝${RESET}"
fi

if ! $HTML_MODE; then
  echo
  echo "${DIM}  Tip: Run with --html to generate HTML report + fix scripts.${RESET}"
  echo
  exit 0
fi

# =============================================================================
# =============================================================================
# ── GENERATE FIX_SYSTEM.SH ───────────────────────────────────────────────────
# =============================================================================
# =============================================================================

echo
echo "${CYAN}  Generating fix scripts and HTML report...${RESET}"

cat > "$FIX_SYS_FILE" << SYSEOF
#!/usr/bin/env bash
# =============================================================================
#  fix_system.sh — Generated by streaming_health_check.sh
#  Date: $(date)
#  Machine: $(hostname)
#  Interface: $OUTBOUND_IFACE
#
#  Fixes everything this machine can fix:
#    1. Kernel / sysctl parameters
#    2. PF firewall multicast block rules
#    3. Multicast routing to loopback
#    4. Power management (pmset)
#
#  CANNOT fix from this machine:
#    - Physical half duplex (switch/cable issue)
#    - Run diagnose_duplex_${TIMESTAMP}.sh for full duplex investigation
#
#  Usage: sudo ./$(basename $FIX_SYS_FILE)
# =============================================================================
set -euo pipefail

RED=\$'\e[31m'; GREEN=\$'\e[32m'; YELLOW=\$'\e[33m'
CYAN=\$'\e[36m'; BOLD=\$'\e[1m'; RESET=\$'\e[0m'

ok()   { echo "  \${GREEN}✅  \$*\${RESET}"; }
doing(){ echo "  \${CYAN}▶   \$*\${RESET}"; }
warn() { echo "  \${YELLOW}⚠️   \$*\${RESET}"; }

if [ "\$(id -u)" -ne 0 ]; then
  echo "\${RED}Must run with sudo\${RESET}"; exit 1
fi

echo
echo "\${BOLD}\${CYAN}╔══════════════════════════════════════════════════════════════╗\${RESET}"
echo "\${BOLD}\${CYAN}║  Streaming Appliance System Fix Script                       ║\${RESET}"
echo "\${BOLD}\${CYAN}║  Generated: $(date)              ║\${RESET}"
echo "\${BOLD}\${CYAN}╚══════════════════════════════════════════════════════════════╝\${RESET}"
echo

# ── 1. Kernel / sysctl ───────────────────────────────────────────────────────
echo "\${BOLD}── Kernel Parameters ─────────────────────────────────────────────\${RESET}"
echo

SYSEOF

# Add sysctl commands detected during check
if [ ${#SYSCTL_FIXES[@]} -gt 0 ]; then
  for cmd in "${SYSCTL_FIXES[@]}"; do
    echo "doing \"${cmd}\"" >> "$FIX_SYS_FILE"
    echo "${cmd}" >> "$FIX_SYS_FILE"
    echo "ok \"Applied\"" >> "$FIX_SYS_FILE"
    echo >> "$FIX_SYS_FILE"
  done
else
  echo 'ok "All kernel parameters already optimal"' >> "$FIX_SYS_FILE"
fi

# Always write the full recommended set regardless
cat >> "$FIX_SYS_FILE" << SYSEOF2

# Ensure full recommended set is applied
doing "Applying full recommended sysctl set..."
sysctl -w net.inet.udp.maxdgram=65535
sysctl -w net.inet.udp.recvspace=1048576
sysctl -w net.inet.udp.sendspace=1048576
sysctl -w kern.ipc.maxsockbuf=8388608
sysctl -w kern.maxfiles=65536
sysctl -w kern.maxfilesperproc=65536
sysctl -w net.inet.tcp.delayed_ack=0
ok "sysctl parameters applied (session only — see note below)"
echo
warn "NOTE: sysctl changes are NOT persistent across reboots."
warn "To make permanent, add each line to /etc/sysctl.conf"
echo

# ── 2. Power management ───────────────────────────────────────────────────────
echo "\${BOLD}── Power Management ──────────────────────────────────────────────\${RESET}"
echo

SYSEOF2

if [ ${#PMSET_FIXES[@]} -gt 0 ]; then
  for cmd in "${PMSET_FIXES[@]}"; do
    echo "doing \"${cmd}\"" >> "$FIX_SYS_FILE"
    echo "${cmd}" >> "$FIX_SYS_FILE"
    echo "ok \"Applied\"" >> "$FIX_SYS_FILE"
    echo >> "$FIX_SYS_FILE"
  done
else
  echo 'ok "All power settings already correct"' >> "$FIX_SYS_FILE"
fi

cat >> "$FIX_SYS_FILE" << SYSEOF3

# Ensure full recommended pmset set
doing "Applying full recommended pmset set..."
pmset -a sleep 0
pmset -a displaysleep 0
pmset -a disksleep 0
pmset -a standby 0
pmset -a powernap 0
pmset -a womp 0
pmset -a autorestart 1
pmset -a lowpowermode 0
pmset -a tcpkeepalive 1
pmset -a networkoversleep 0
ok "Power settings applied"
echo

# ── 3. Multicast routing ─────────────────────────────────────────────────────
echo "\${BOLD}── Multicast Routing ─────────────────────────────────────────────\${RESET}"
echo

doing "Removing any existing multicast route..."
route delete -net 224.0.0.0/4 >/dev/null 2>&1 || true
ok "Old routes cleared"

doing "Adding loopback multicast route..."
route -n add -net 224.0.0.0/4 127.0.0.1
ok "224.0.0.0/4 → 127.0.0.1 (lo0)"
echo

warn "NOTE: Route changes do NOT persist across reboots."
warn "Add to a login item or launchd job to re-apply on boot."
echo

# ── 4. PF Firewall ────────────────────────────────────────────────────────────
echo "\${BOLD}── PF Firewall ───────────────────────────────────────────────────\${RESET}"
echo

IFACE="${OUTBOUND_IFACE}"
PF_RULE_OUT="block out quick on \${IFACE} proto udp to 224.0.0.0/4"
PF_RULE_IN="block in  quick on \${IFACE} proto udp to 224.0.0.0/4"

doing "Checking for existing PF multicast rules..."
if pfctl -sr 2>/dev/null | grep -q "block.*\${IFACE}.*224\.0\.0\.0"; then
  ok "PF rules already present for \${IFACE}"
else
  doing "Adding PF block rules to /etc/pf.conf..."
  # Backup first
  cp /etc/pf.conf /etc/pf.conf.bak.\$(date +%Y%m%d%H%M%S)
  ok "Backed up /etc/pf.conf"
  # Remove any old versions of our rules to avoid duplicates
  grep -v "block.*\${IFACE}.*224\.0\.0\.0" /etc/pf.conf > /tmp/pf.conf.tmp && mv /tmp/pf.conf.tmp /etc/pf.conf
  echo "" >> /etc/pf.conf
  echo "# Streaming appliance: block multicast on physical NIC" >> /etc/pf.conf
  echo "\${PF_RULE_OUT}" >> /etc/pf.conf
  echo "\${PF_RULE_IN}"  >> /etc/pf.conf
  ok "Rules written to /etc/pf.conf"
fi

doing "Loading and enabling PF..."
pfctl -f /etc/pf.conf
pfctl -e 2>/dev/null || true
ok "PF enabled and rules loaded"
echo

# ── 5. Verification ──────────────────────────────────────────────────────────
echo "\${BOLD}── Verification ──────────────────────────────────────────────────\${RESET}"
echo
echo "  Verifying sysctl:"
sysctl net.inet.udp.recvspace net.inet.udp.sendspace kern.ipc.maxsockbuf | sed 's/^/    /'
echo
echo "  Verifying PF rules:"
pfctl -sr 2>/dev/null | grep "224" | sed 's/^/    /' || echo "    (no multicast rules found — check /etc/pf.conf)"
echo
echo "  Verifying multicast route:"
netstat -rn | grep "^22" | sed 's/^/    /' || echo "    (no multicast routes)"
echo
echo "  Verifying pmset:"
pmset -g | grep -E "sleep|powernap|autorestart|womp|lowpowermode" | sed 's/^/    /'
echo
echo "\${GREEN}\${BOLD}  fix_system.sh complete.\${RESET}"
echo "\${CYAN}  Re-run streaming_health_check.sh --html to verify all issues resolved.\${RESET}"
echo
SYSEOF3

chmod +x "$FIX_SYS_FILE"

# =============================================================================
# ── GENERATE FIX_FFMPEG_COMMANDS.SH ──────────────────────────────────────────
# =============================================================================

# Build recommended sender command from detected values
REC_INPUT="${INPUT_SRC:-DeckLink SDI}"
REC_VBR="${VBR_RAW:-4000k}"
REC_ABR="${ABR_RAW:-128k}"
REC_ACODEC="${ACODEC:-aac}"
REC_BUFSIZE="$(echo "scale=0;$(parse_bitrate $REC_VBR)*2" | bc 2>/dev/null || echo 8000)k"
REC_GROUP="$MCAST_GROUP"
REC_PORT="$MCAST_PORT"

# Detect if YouTube stream key is in existing command
YT_KEY=$(echo "$YOUTUBE_CMD" | grep -oE 'rtmp://[^ ]+' | head -1 || echo "rtmp://a.rtmp.youtube.com/live2/YOUR_STREAM_KEY")
WEBRTC_PORT=$(echo "$WEBRTC_CMD" | grep -oE 'udp://127\.0\.0\.1:[0-9]+' | grep -oE '[0-9]+$' || echo "5000")

cat > "$FIX_FFMPEG_FILE" << FFEOF
#!/usr/bin/env bash
# =============================================================================
#  fix_ffmpeg_commands.sh — Generated by streaming_health_check.sh
#  Date: $(date)
#
#  Recommended corrected FFmpeg commands for your streaming pipeline.
#  These are PRINT ONLY — review and run manually.
#
#  Key changes from detected configuration:
#    - Video encoder: h264_videotoolbox (Apple GPU — lower CPU usage)
#    - localaddr=127.0.0.1 — multicast bound to loopback only
#    - ttl=0              — cannot route beyond this host
#    - pkt_size=1316      — optimal MPEG-TS packet size
#    - preset veryfast    — low latency, low CPU
#    - tune zerolatency   — no b-frame buffering
#    - explicit maxrate   — prevents encoder bursting above target
# =============================================================================

CYAN=\$'\e[36m'; BOLD=\$'\e[1m'; DIM=\$'\e[2m'; GREEN=\$'\e[32m'; RESET=\$'\e[0m'

echo
echo "\${BOLD}\${CYAN}╔══════════════════════════════════════════════════════════════╗\${RESET}"
echo "\${BOLD}\${CYAN}║  Recommended FFmpeg Commands                                  ║\${RESET}"
echo "\${BOLD}\${CYAN}╚══════════════════════════════════════════════════════════════╝\${RESET}"
echo

# ─────────────────────────────────────────────────────────────────────────────
echo "\${BOLD}── COMMAND 1: Sender (DeckLink → Multicast) ─────────────────────\${RESET}"
echo
echo "\${DIM}# h264_videotoolbox uses Apple's hardware encoder — much lower CPU"
echo "# than libx264. Frees CPU headroom for the rest of the pipeline."
echo "# localaddr + ttl=0 keeps multicast strictly on loopback."
echo "# maxrate + bufsize caps bitrate bursts to protect receiver buffers.\${RESET}"
echo
echo "\${GREEN}ffmpeg \\\\
  -f decklink \\\\
  -i \"${REC_INPUT}\" \\\\
  -c:v h264_videotoolbox \\\\
  -b:v ${REC_VBR} \\\\
  -maxrate ${REC_VBR} \\\\
  -bufsize ${REC_BUFSIZE} \\\\
  -profile:v high \\\\
  -level 4.1 \\\\
  -c:a ${REC_ACODEC} \\\\
  -b:a ${REC_ABR} \\\\
  -f mpegts \\\\
  \"udp://${REC_GROUP}:${REC_PORT}?localaddr=127.0.0.1&ttl=0&pkt_size=1316\"\${RESET}"
echo

# ─────────────────────────────────────────────────────────────────────────────
echo "\${BOLD}── COMMAND 2: Receiver → YouTube (Multicast → RTMP) ─────────────\${RESET}"
echo
echo "\${DIM}# Reads from the multicast bus and forwards to YouTube.
# -c:v copy / -c:a copy — no re-encoding. Zero CPU overhead.
# localaddr=127.0.0.1 on input — only reads from loopback.
# Replace YOUR_STREAM_KEY with your actual YouTube stream key.\${RESET}"
echo
echo "\${GREEN}ffmpeg \\\\
  -i \"udp://${REC_GROUP}:${REC_PORT}?localaddr=127.0.0.1\" \\\\
  -c:v copy \\\\
  -c:a copy \\\\
  -f flv \\\\
  \"${YT_KEY}\"\${RESET}"
echo

# ─────────────────────────────────────────────────────────────────────────────
echo "\${BOLD}── COMMAND 3: Receiver → WebRTC (Multicast → unicast UDP) ───────\${RESET}"
echo
echo "\${DIM}# Reads from multicast bus and outputs to localhost unicast UDP.
# Your WebRTC process listens on 127.0.0.1:${WEBRTC_PORT}.
# -c:v copy / -c:a copy — no re-encoding.
# Adjust port if your WebRTC process uses a different port.\${RESET}"
echo
echo "\${GREEN}ffmpeg \\\\
  -i \"udp://${REC_GROUP}:${REC_PORT}?localaddr=127.0.0.1\" \\\\
  -c:v copy \\\\
  -c:a copy \\\\
  -f mpegts \\\\
  \"udp://127.0.0.1:${WEBRTC_PORT}\"\${RESET}"
echo

# ─────────────────────────────────────────────────────────────────────────────
echo "\${BOLD}── STARTUP ORDER ─────────────────────────────────────────────────\${RESET}"
echo
echo "\${DIM}# Always start in this order:
# 1. Start receivers first (they will wait for the multicast stream)
# 2. Start sender last
# This prevents receivers from missing the start of the stream.\${RESET}"
echo
echo "\${DIM}# To run each in background:\${RESET}"
echo "\${DIM}# ffmpeg [receiver args] &\${RESET}"
echo "\${DIM}# ffmpeg [receiver args] &\${RESET}"
echo "\${DIM}# sleep 1\${RESET}"
echo "\${DIM}# ffmpeg [sender args] &\${RESET}"
echo

# ─────────────────────────────────────────────────────────────────────────────
echo "\${BOLD}── h264_videotoolbox vs libx264 ──────────────────────────────────\${RESET}"
echo
echo "\${DIM}  h264_videotoolbox:
    + Uses Apple GPU hardware encoder — very low CPU overhead
    + Frees significant CPU for other FFmpeg processes
    + Lower heat, longer sustained operation
    - Slightly lower quality per bit vs libx264
    - Less tuning options (no preset/tune flags)

  libx264 (fallback if videotoolbox unavailable):
    ffmpeg -f decklink -i \"${REC_INPUT}\" \\\\
      -c:v libx264 -preset veryfast -tune zerolatency \\\\
      -b:v ${REC_VBR} -maxrate ${REC_VBR} -bufsize ${REC_BUFSIZE} \\\\
      -c:a ${REC_ACODEC} -b:a ${REC_ABR} \\\\
      -f mpegts \\\\
      \"udp://${REC_GROUP}:${REC_PORT}?localaddr=127.0.0.1&ttl=0&pkt_size=1316\"\${RESET}"
echo
FFEOF

chmod +x "$FIX_FFMPEG_FILE"

# =============================================================================
# ── GENERATE DIAGNOSE_DUPLEX.SH ──────────────────────────────────────────────
# =============================================================================

cat > "$DIAG_DUPLEX_FILE" << DUPLEXEOF
#!/usr/bin/env bash
# =============================================================================
#  diagnose_duplex.sh — Generated by streaming_health_check.sh
#  Date: $(date)
#  Interface: $OUTBOUND_IFACE
#
#  Half duplex and link quality investigation tool.
#
#  IMPORTANT: Half duplex cannot be fixed from this machine alone.
#  It requires physical intervention at the cable or switch.
#  This script tells you EXACTLY what to check and where.
#
#  Usage: sudo ./$(basename $DIAG_DUPLEX_FILE) [seconds]
#  Default sample time: 30 seconds
# =============================================================================
set -uo pipefail

IFACE="${OUTBOUND_IFACE}"
SAMPLE="\${1:-30}"

RED=\$'\e[31m'; GREEN=\$'\e[32m'; YELLOW=\$'\e[33m'
CYAN=\$'\e[36m'; BOLD=\$'\e[1m'; DIM=\$'\e[2m'; RESET=\$'\e[0m'

ok()    { echo "  \${GREEN}✅  \$*\${RESET}"; }
fail()  { echo "  \${RED}🚨  \$*\${RESET}"; }
warn()  { echo "  \${YELLOW}⚠️   \$*\${RESET}"; }
info()  { echo "  \${DIM}    \$*\${RESET}"; }
note()  { echo "  \${CYAN}    \$*\${RESET}"; }
blank() { echo; }
section(){ echo; echo "\${BOLD}\${CYAN}── \$1 ─────────────────────────────────────────────\${RESET}"; echo; }

clear
echo
echo "\${BOLD}\${CYAN}╔══════════════════════════════════════════════════════════════╗\${RESET}"
echo "\${BOLD}\${CYAN}║  Half Duplex & Link Quality Diagnostic                       ║\${RESET}"
echo "\${BOLD}\${CYAN}║  Interface: \$IFACE   Sample: \${SAMPLE}s                        ║\${RESET}"
echo "\${BOLD}\${CYAN}╚══════════════════════════════════════════════════════════════╝\${RESET}"
echo

# ── What half duplex means here ───────────────────────────────────────────────
section "What Half Duplex Means For Your Stream"

echo "  Half duplex means your NIC can only SEND or RECEIVE — never both"
echo "  at the same time. For streaming this is catastrophic:"
blank
info "  While sending video to YouTube:  incoming ACKs must WAIT"
info "  While receiving an ACK:          outgoing video must PAUSE"
info "  Result: stuttering, retransmits, rising latency, stream drops"
blank
warn "  Half duplex is NOT a software problem."
warn "  It cannot be fixed by changing macOS settings."
warn "  Root cause is always: cable, switch port, or NIC."
blank

# ── Current negotiated state ──────────────────────────────────────────────────
section "Current Negotiated Link State"

MEDIA=\$(ifconfig "\$IFACE" 2>/dev/null | grep -iE "media:" || true)
note "Raw media info: \$MEDIA"
blank

if echo "\$MEDIA" | grep -qi "half"; then
  fail "HALF DUPLEX CONFIRMED on \$IFACE"
  fail "This machine is actively operating in half duplex right now"
elif echo "\$MEDIA" | grep -qi "full"; then
  ok "Full duplex confirmed on \$IFACE"
  info "If you are still seeing stream problems, proceed with error counter trend analysis below"
elif echo "\$MEDIA" | grep -qi "autoselect"; then
  warn "Interface reports 'autoselect' — negotiation may not have completed"
  info "Check switch port for forced settings"
else
  warn "Duplex state unclear from media string"
  info "Proceed with error counter trend analysis"
fi

# ── Live error counter trend ──────────────────────────────────────────────────
section "Live Error & Collision Counter Trend (\${SAMPLE}s)"

info "Sampling counters before and after \${SAMPLE} seconds of traffic..."
info "With your stream running, rising collision or error counters confirm half duplex."
blank

get_counters() {
  netstat -ibn -I "\$1" 2>/dev/null \
    | awk 'NR>1{rxp+=\$5;txp+=\$8;rxe+=\$6;txe+=\$9;col+=\$11}
           END{print rxp+0,txp+0,rxe+0,txe+0,col+0}'
}

read RXP0 TXP0 RXE0 TXE0 COL0 < <(get_counters "\$IFACE")
echo "  Before — RX:\$RXP0  TX:\$TXP0  RX_err:\$RXE0  TX_err:\$TXE0  Collisions:\$COL0"

for i in \$(seq "\$SAMPLE" -1 1); do
  printf "\r  \${DIM}Sampling... %2ds remaining   \${RESET}" "\$i"; sleep 1
done
printf "\r  \${GREEN}Done.                            \${RESET}\n\n"

read RXP1 TXP1 RXE1 TXE1 COL1 < <(get_counters "\$IFACE")
echo "  After  — RX:\$RXP1  TX:\$TXP1  RX_err:\$RXE1  TX_err:\$TXE1  Collisions:\$COL1"
blank

DELTA_RXE=\$((RXE1 - RXE0))
DELTA_TXE=\$((TXE1 - TXE0))
DELTA_COL=\$((COL1 - COL0))
DELTA_TXP=\$((TXP1 - TXP0))

note "Delta over \${SAMPLE}s — RX_errors: \$DELTA_RXE  TX_errors: \$DELTA_TXE  Collisions: \$DELTA_COL"
blank

if [ "\$DELTA_COL" -gt 0 ]; then
  fail "RISING COLLISIONS: +\$DELTA_COL over \${SAMPLE}s"
  fail "Collisions are physically impossible on full-duplex."
  fail "This is definitive proof of half duplex operation."
elif [ "\$DELTA_RXE" -gt 0 ] || [ "\$DELTA_TXE" -gt 0 ]; then
  warn "Rising errors: RX+\$DELTA_RXE  TX+\$DELTA_TXE — possible cable or NIC issue"
  info "May not be half duplex — could be cable quality or NIC problem"
else
  ok "No rising errors or collisions during sample period"
  info "If duplex reported as unknown, link may actually be healthy"
fi

# ── Mac-side forced setting check ────────────────────────────────────────────
section "Mac-Side Forced Settings (Things You CAN Change Here)"

CURRENT_MEDIA=\$(ifconfig "\$IFACE" 2>/dev/null | grep -iE "media:" | head -1 || true)
note "Current media setting: \$CURRENT_MEDIA"
blank

if echo "\$CURRENT_MEDIA" | grep -qi "autoselect"; then
  ok "Mac side is set to autoselect (autonegotiation)"
  info "This is correct. The problem is at the switch or cable — see below."
else
  warn "Mac side has a FORCED media setting"
  warn "A forced setting can cause duplex mismatch if switch expects autoneg"
  echo
  echo "  \${BOLD}To reset Mac side to autonegotiation:\${RESET}"
  echo "  \${BOLD}sudo ifconfig \$IFACE media autoselect\${RESET}"
fi

# ── Switch-side investigation ─────────────────────────────────────────────────
section "Switch-Side Investigation (Cannot Check From This Machine)"

echo "  The switch port is the most common cause of half duplex."
echo "  You must check it directly. Here is exactly what to do:"
blank

echo "  \${BOLD}── Step 1: Identify which switch and port ────────────────────\${RESET}"
blank
info "  Follow the cable from your Mac to the switch"
info "  Note the switch model and port number"
info "  If using a patch panel, trace to the actual switch port"
blank

echo "  \${BOLD}── Step 2: Check the port on common switches ─────────────────\${RESET}"
blank

echo "  \${CYAN}UniFi (Ubiquiti):\${RESET}"
info "    UniFi Controller → Devices → [switch] → Ports"
info "    Find your port → check Speed/Duplex"
info "    Should show: 1000 Mbps Full Duplex"
info "    If showing 100/Half: port is forced or cable is bad"
blank

echo "  \${CYAN}Cisco Catalyst / IOS:\${RESET}"
info "    SSH into switch"
info "    show interface GigabitEthernetX/X"
info "    Look for: 'Full-duplex' and '1000Mb/s'"
info "    If Half-duplex: run 'duplex full' under the interface"
blank

echo "  \${CYAN}Cisco SG series (web UI):\${RESET}"
info "    Admin UI → Port Management → Port Settings"
info "    Check Speed/Duplex column for your port"
blank

echo "  \${CYAN}Netgear managed (web UI):\${RESET}"
info "    Switching → Ports → Port Configuration"
info "    Speed/Duplex should be Auto or 1000M-Full"
blank

echo "  \${CYAN}TP-Link managed (web UI):\${RESET}"
info "    Switching → Port → Port Config"
info "    Speed and Duplex column"
blank

echo "  \${CYAN}Generic unmanaged switch:\${RESET}"
info "    No configuration interface"
info "    If half duplex, the switch itself is faulty or overloaded"
info "    Try a different port, or replace the switch"
blank

echo "  \${BOLD}── Step 3: Cable tests ───────────────────────────────────────\${RESET}"
blank

info "  Half duplex is often caused by marginal cable quality:"
blank
echo "  \${CYAN}Things to check:\${RESET}"
info "    Cable length: >90m can cause negotiation fallback"
info "    Cable category: Cat5e minimum for Gigabit, Cat6 preferred"
info "    Connectors: re-crimp or replace RJ45 ends if bent/dirty"
info "    Try a known-good short patch cable direct to switch"
info "    Eliminate patch panels — connect directly if possible"
blank

echo "  \${CYAN}Quick test:\${RESET}"
info "    Replace cable with a short (1-2m) Cat6 patch cable"
info "    If duplex improves: original cable is faulty or too long"
blank

echo "  \${BOLD}── Step 4: Force Gigabit Full Duplex on Mac (last resort) ───\${RESET}"
blank
warn "  Only use forced settings if autonegotiation keeps failing."
warn "  Both ends must be forced to the same speed/duplex — mismatch is worse."
blank
echo "  \${BOLD}  sudo ifconfig \$IFACE media 1000baseT mediaopt full-duplex\${RESET}"
blank
info "  To revert to autoneg:"
echo "  \${BOLD}  sudo ifconfig \$IFACE media autoselect\${RESET}"
blank
warn "  If you force this without also forcing the switch port, you may"
warn "  create a duplex mismatch which is worse than half duplex."
blank

# ── Summary ───────────────────────────────────────────────────────────────────
section "Summary & Recommended Actions"

if [ "\$DELTA_COL" -gt 0 ]; then
  fail "Half duplex CONFIRMED by rising collisions"
  echo
  echo "  \${BOLD}Priority actions:\${RESET}"
  echo "  1. Try replacing the cable with a short Cat6 patch cable"
  echo "  2. Check switch port duplex setting (see switch instructions above)"
  echo "  3. If switch port was forced to half: set to Auto or Full"
  echo "  4. If problem persists after cable and switch checks: try different switch port"
elif echo "\$MEDIA" | grep -qi "half"; then
  fail "Half duplex reported by interface"
  echo
  echo "  \${BOLD}Priority actions:\${RESET}"
  echo "  1. Check switch port configuration (see above)"
  echo "  2. Replace cable"
  echo "  3. Try: sudo ifconfig \$IFACE media autoselect"
else
  ok "No active half duplex detected during this run"
  info "If stream problems persist, run this script again with stream active"
  info "and monitor the collision counter trend section carefully"
fi

echo
echo "\${DIM}  Re-run after making changes: sudo ./\$(basename \$0)\${RESET}"
echo
DUPLEXEOF

chmod +x "$DIAG_DUPLEX_FILE"

# =============================================================================
# ── GENERATE HTML REPORT ─────────────────────────────────────────────────────
# =============================================================================

# Build section HTML helper
build_section_html() {
  local key="$1" title="$2"
  local html="<div class='report-section'><h2 class='section-title'>$(html_esc "$title")</h2><div class='checks'>"
  local found=false
  for check in "${ALL_CHECKS[@]:-}"; do
    IFS='|||' read -r status section ctitle value expl fix <<< "$check"
    [ "$section" != "$key" ] && continue
    found=true
    local icon="" cls=""
    case "$status" in
      ok)   icon="✅"; cls="check-ok"   ;;
      warn) icon="⚠️";  cls="check-warn" ;;
      fail) icon="🚨"; cls="check-fail" ;;
      info) icon="ℹ️";  cls="check-info" ;;
    esac
    local fix_html=""
    if [ -n "$fix" ]; then
      local fix_esc; fix_esc=$(html_esc "$fix")
      fix_html="<div class='fix-block'><span class='fix-label'>Fix Command</span><code class='fix-cmd'>${fix_esc}</code></div>"
    fi
    local val_esc; val_esc=$(html_esc "$value")
    local title_esc; title_esc=$(html_esc "$ctitle")
    html+="<div class='check-row ${cls}'>
      <div class='check-icon'>${icon}</div>
      <div class='check-body'>
        <div class='check-title-row'>
          <span class='check-title'>${title_esc}</span>
          <span class='check-value'>${val_esc}</span>
        </div>
        <div class='check-expl'>$(html_esc "$expl")</div>
        ${fix_html}
      </div>
    </div>"
  done
  $found || html+="<div class='check-row check-info'><div class='check-icon'>ℹ️</div><div class='check-body'><div class='check-title-row'><span class='check-title'>No checks in this section</span></div></div></div>"
  html+="</div></div>"
  echo "$html"
}

# Process cards
PROC_CARDS_HTML=""
for proc in "${FFMPEG_PROCS[@]:-}"; do
  IFS='|||' read -r pid role cpu mem fds started cmd <<< "$proc"
  case "$role" in
    sender)  rlabel="SENDER → MULTICAST" ;;
    youtube) rlabel="RECEIVER → YOUTUBE"  ;;
    webrtc)  rlabel="RECEIVER → WEBRTC"   ;;
    *)       rlabel="UNKNOWN"              ;;
  esac
  cmd_esc=$(html_esc "$cmd")
  PROC_CARDS_HTML+="<div class='proc-card proc-${role}'>
    <div class='proc-header'>
      <span class='proc-pid'>PID ${pid}</span>
      <span class='proc-badge badge-${role}'>${rlabel}</span>
    </div>
    <div class='proc-stats'>
      <span>CPU <strong>${cpu}%</strong></span>
      <span>MEM <strong>${mem}</strong></span>
      <span>FDs <strong>${fds}</strong></span>
    </div>
    <div class='proc-started'>Started: ${started}</div>
    <div class='proc-cmd'><code>${cmd_esc}</code></div>
  </div>"
done

# Fix commands HTML
FIX_HTML=""
for cmd in "${FIX_COMMANDS[@]:-}"; do
  cmd_esc=$(html_esc "$cmd")
  if [[ "$cmd" == \#* ]]; then
    FIX_HTML+="<div class='fix-comment'>${cmd_esc}</div>"
  else
    FIX_HTML+="<div class='fix-line'><code>${cmd_esc}</code></div>"
  fi
done

# Recommended command (HTML-escaped)
REC_CMD_ESC=$(html_esc "ffmpeg \\
  -f decklink \\
  -i \"${REC_INPUT}\" \\
  -c:v h264_videotoolbox \\
  -b:v ${REC_VBR} \\
  -maxrate ${REC_VBR} \\
  -bufsize ${REC_BUFSIZE} \\
  -profile:v high -level 4.1 \\
  -c:a ${REC_ACODEC} -b:a ${REC_ABR} \\
  -f mpegts \\
  \"udp://${REC_GROUP}:${REC_PORT}?localaddr=127.0.0.1&ttl=0&pkt_size=1316\"")

# Bandwidth bar
BAR_PCT="${RATIO:-0}"
[ "${BAR_PCT:-0}" -gt 115 ] && BAR_COLOR="#f59e0b" || BAR_COLOR="#10b981"
[ "${BAR_PCT:-0}" -lt 70  ] && BAR_COLOR="#ef4444"

# Status
if   [ "$ISSUES" -eq 0 ] && [ "$WARNINGS" -eq 0 ] && $LEAK_OK; then
  OVERALL_CLASS="status-ok";   OVERALL_ICON="✅"; OVERALL_TEXT="FULLY HEALTHY"
  OVERALL_SUB="All checks passed. Ready for production streaming."
elif [ "$ISSUES" -eq 0 ]; then
  OVERALL_CLASS="status-warn"; OVERALL_ICON="⚠️"; OVERALL_TEXT="MOSTLY HEALTHY"
  OVERALL_SUB="${WARNINGS} warning(s) to review."
else
  OVERALL_CLASS="status-fail"; OVERALL_ICON="🚨"; OVERALL_TEXT="NOT READY"
  OVERALL_SUB="${ISSUES} critical issue(s) must be fixed."
fi

cat > "$REPORT_FILE" << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Streaming Health Report — $(date)</title>
<style>
@import url('https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;600&family=IBM+Plex+Sans:wght@300;400;500;600&display=swap');
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{
  --bg:#0a0a12;--surface:#11111e;--surface2:#181828;--border:#1f1f38;
  --accent:#6366f1;--green:#10b981;--yellow:#f59e0b;--red:#ef4444;
  --text:#e2e8f0;--muted:#64748b;
  --mono:'IBM Plex Mono',monospace;--sans:'IBM Plex Sans',sans-serif;
}
html{scroll-behavior:smooth}
body{background:var(--bg);color:var(--text);font-family:var(--sans);font-size:14px;line-height:1.6;min-height:100vh}
.layout{display:grid;grid-template-columns:220px 1fr;min-height:100vh}
.sidebar{background:var(--surface);border-right:1px solid var(--border);padding:24px 0;position:sticky;top:0;height:100vh;overflow-y:auto}
.sidebar-logo{padding:0 20px 20px;border-bottom:1px solid var(--border)}
.sidebar-logo h1{font-family:var(--mono);font-size:12px;color:var(--accent);letter-spacing:.08em;text-transform:uppercase}
.sidebar-logo p{font-size:11px;color:var(--muted);margin-top:4px}
.nav-item{display:block;padding:7px 20px;font-size:12px;color:var(--muted);text-decoration:none;font-family:var(--mono);letter-spacing:.03em;border-left:2px solid transparent;transition:all .15s}
.nav-item:hover{color:var(--text);border-left-color:var(--accent);background:rgba(99,102,241,.06)}
.main{padding:36px 44px;max-width:1060px}
.hero{border-radius:12px;padding:28px 32px;margin-bottom:36px;border:1px solid var(--border);position:relative;overflow:hidden}
.status-ok  {background:linear-gradient(135deg,#052e16,var(--bg));border-color:var(--green)}
.status-warn{background:linear-gradient(135deg,#1c1100,var(--bg));border-color:var(--yellow)}
.status-fail{background:linear-gradient(135deg,#1c0505,var(--bg));border-color:var(--red)}
.hero-icon{font-size:44px;line-height:1;margin-bottom:10px}
.hero-title{font-family:var(--mono);font-size:26px;font-weight:600;letter-spacing:.06em}
.status-ok .hero-title{color:var(--green)}.status-warn .hero-title{color:var(--yellow)}.status-fail .hero-title{color:var(--red)}
.hero-sub{color:var(--muted);margin-top:6px;font-size:14px}
.hero-meta{margin-top:18px;display:flex;gap:28px;flex-wrap:wrap}
.hero-stat{display:flex;flex-direction:column;gap:2px}
.hero-stat-label{font-size:10px;color:var(--muted);text-transform:uppercase;letter-spacing:.08em;font-family:var(--mono)}
.hero-stat-val{font-family:var(--mono);font-size:20px;font-weight:600}
.val-ok{color:var(--green)}.val-warn{color:var(--yellow)}.val-fail{color:var(--red)}
.hero-ts{position:absolute;top:18px;right:22px;font-family:var(--mono);font-size:11px;color:var(--muted)}
.generated-files{background:var(--surface);border:1px solid var(--border);border-left:3px solid var(--accent);border-radius:10px;padding:18px 22px;margin-bottom:32px}
.generated-files h3{font-family:var(--mono);font-size:12px;color:var(--accent);text-transform:uppercase;letter-spacing:.08em;margin-bottom:12px}
.file-item{display:flex;align-items:baseline;gap:10px;padding:5px 0;border-bottom:1px solid var(--border)}
.file-item:last-child{border-bottom:none}
.file-name{font-family:var(--mono);font-size:12px;color:var(--text);font-weight:600}
.file-desc{font-size:12px;color:var(--muted)}
.report-section{margin-bottom:36px;scroll-margin-top:20px}
.section-title{font-family:var(--mono);font-size:12px;text-transform:uppercase;letter-spacing:.1em;color:var(--accent);margin-bottom:14px;padding-bottom:8px;border-bottom:1px solid var(--border)}
.checks{display:flex;flex-direction:column;gap:9px}
.check-row{display:grid;grid-template-columns:34px 1fr;gap:10px;padding:13px 15px;border-radius:8px;border:1px solid var(--border);background:var(--surface);transition:border-color .15s}
.check-row:hover{border-color:var(--accent)}
.check-ok  {border-left:3px solid var(--green)}
.check-warn{border-left:3px solid var(--yellow)}
.check-fail{border-left:3px solid var(--red);background:#110a0a}
.check-info{border-left:3px solid var(--muted)}
.check-icon{font-size:17px;padding-top:1px}
.check-title-row{display:flex;justify-content:space-between;align-items:baseline;gap:10px;flex-wrap:wrap}
.check-title{font-family:var(--mono);font-size:12px;font-weight:600;color:var(--text)}
.check-value{font-family:var(--mono);font-size:11px;background:var(--surface2);padding:2px 8px;border-radius:4px;color:var(--accent);white-space:nowrap}
.check-expl{margin-top:5px;font-size:12px;color:var(--muted);line-height:1.5}
.fix-block{margin-top:9px;background:#0d1117;border:1px solid #2d2d4e;border-radius:6px;padding:9px 13px}
.fix-label{font-family:var(--mono);font-size:10px;color:var(--yellow);text-transform:uppercase;letter-spacing:.08em;display:block;margin-bottom:4px}
.fix-cmd{font-family:var(--mono);font-size:11px;color:#e2e8f0;word-break:break-all;white-space:pre-wrap}
.proc-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:12px;margin-bottom:32px}
.proc-card{border-radius:10px;padding:14px;border:1px solid var(--border);background:var(--surface)}
.proc-sender {border-color:var(--green)}.proc-youtube{border-color:var(--accent)}.proc-webrtc{border-color:#8b5cf6}.proc-unknown{border-color:var(--muted)}
.proc-header{display:flex;justify-content:space-between;align-items:center;margin-bottom:8px}
.proc-pid{font-family:var(--mono);font-size:13px;font-weight:600}
.proc-badge{font-family:var(--mono);font-size:10px;padding:2px 7px;border-radius:4px;text-transform:uppercase;letter-spacing:.05em}
.badge-sender {background:rgba(16,185,129,.15);color:var(--green)}
.badge-youtube{background:rgba(99,102,241,.15);color:var(--accent)}
.badge-webrtc {background:rgba(139,92,246,.15);color:#a78bfa}
.badge-unknown{background:rgba(100,116,139,.15);color:var(--muted)}
.proc-stats{display:flex;gap:14px;margin-bottom:6px;font-size:12px;color:var(--muted)}
.proc-stats strong{color:var(--text)}
.proc-started{font-size:11px;color:var(--muted);font-family:var(--mono);margin-bottom:8px}
.proc-cmd{background:#0d1117;border-radius:6px;padding:9px;overflow-x:auto}
.proc-cmd code{font-family:var(--mono);font-size:11px;color:#94a3b8;white-space:pre-wrap;word-break:break-all}
.bw-card{background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:18px 22px;margin-bottom:32px}
.bw-title{font-family:var(--mono);font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.08em;margin-bottom:12px}
.bw-nums{display:flex;gap:24px;flex-wrap:wrap;margin-bottom:10px}
.bw-nums span{font-family:var(--mono);font-size:12px;color:var(--muted)}
.bw-nums strong{color:var(--text)}
.bw-track{height:10px;background:var(--surface2);border-radius:5px;overflow:hidden}
.bw-fill{height:100%;border-radius:5px;transition:width .6s ease}
.bw-labels{display:flex;justify-content:space-between;margin-top:5px}
.bw-labels span{font-size:10px;color:var(--muted);font-family:var(--mono)}
.topo-card{background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:22px;margin-bottom:32px}
.topo-title{font-family:var(--mono);font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.08em;margin-bottom:14px}
.rec-card{background:#0d1117;border:1px solid #2d2d4e;border-left:3px solid var(--green);border-radius:10px;padding:18px 22px;margin-bottom:32px}
.rec-title{font-family:var(--mono);font-size:11px;color:var(--green);text-transform:uppercase;letter-spacing:.08em;margin-bottom:10px}
.rec-desc{font-size:12px;color:var(--muted);margin-bottom:12px}
.rec-code{font-family:var(--mono);font-size:12px;color:#e2e8f0;white-space:pre-wrap;line-height:1.8}
.fixes-card{background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:18px 22px;margin-bottom:32px}
.fixes-title{font-family:var(--mono);font-size:11px;color:var(--yellow);text-transform:uppercase;letter-spacing:.08em;margin-bottom:12px}
.fix-comment{font-family:var(--mono);font-size:11px;color:var(--muted);padding:2px 0}
.fix-line{padding:5px 0}
.fix-line code{font-family:var(--mono);font-size:12px;color:#e2e8f0}
::-webkit-scrollbar{width:5px;height:5px}
::-webkit-scrollbar-track{background:var(--bg)}
::-webkit-scrollbar-thumb{background:var(--border);border-radius:3px}
</style>
</head>
<body>
<div class="layout">
<aside class="sidebar">
  <div class="sidebar-logo">
    <h1>Health Report</h1>
    <p>$(date "+%d %b %Y %H:%M")</p>
  </div>
  <nav style="padding:14px 0">
    <a class="nav-item" href="#overview">Overview</a>
    <a class="nav-item" href="#generated">Generated Scripts</a>
    <a class="nav-item" href="#processes">FFmpeg Processes</a>
    <a class="nav-item" href="#topology">Topology</a>
    <a class="nav-item" href="#bandwidth">Bandwidth</a>
    <a class="nav-item" href="#sender">Sender Analysis</a>
    <a class="nav-item" href="#network">Network Interface</a>
    <a class="nav-item" href="#routing">Multicast Routing</a>
    <a class="nav-item" href="#firewall">PF Firewall</a>
    <a class="nav-item" href="#kernel">Kernel Parameters</a>
    <a class="nav-item" href="#resources">Resources &amp; Power</a>
    <a class="nav-item" href="#leak">Leak Test</a>
    <a class="nav-item" href="#recommended">Recommended Command</a>
    <a class="nav-item" href="#fixes">All Fixes</a>
  </nav>
</aside>
<main class="main">

  <div id="overview" class="hero ${OVERALL_CLASS}">
    <div class="hero-ts">$(date "+%Y-%m-%d %H:%M:%S")</div>
    <div class="hero-icon">${OVERALL_ICON}</div>
    <div class="hero-title">${OVERALL_TEXT}</div>
    <div class="hero-sub">${OVERALL_SUB}</div>
    <div class="hero-meta">
      <div class="hero-stat"><span class="hero-stat-label">Passed</span><span class="hero-stat-val val-ok">${PASSES}</span></div>
      <div class="hero-stat"><span class="hero-stat-label">Warnings</span><span class="hero-stat-val val-warn">${WARNINGS}</span></div>
      <div class="hero-stat"><span class="hero-stat-label">Critical</span><span class="hero-stat-val val-fail">${ISSUES}</span></div>
      <div class="hero-stat"><span class="hero-stat-label">Interface</span><span class="hero-stat-val" style="font-size:15px;color:#a5b4fc">${OUTBOUND_IFACE}</span></div>
      <div class="hero-stat"><span class="hero-stat-label">Link</span><span class="hero-stat-val" style="font-size:15px;color:#a5b4fc">${LINK_SPEED} / ${DUPLEX}</span></div>
      <div class="hero-stat"><span class="hero-stat-label">Multicast</span><span class="hero-stat-val" style="font-size:15px;color:#a5b4fc">${MCAST_GROUP}:${MCAST_PORT}</span></div>
    </div>
  </div>

  <div id="generated" class="generated-files">
    <h3>Generated Files (same folder as script)</h3>
    <div class="file-item">
      <span class="file-name">$(basename $REPORT_FILE)</span>
      <span class="file-desc">This report</span>
    </div>
    <div class="file-item">
      <span class="file-name">$(basename $FIX_SYS_FILE)</span>
      <span class="file-desc">Fixes kernel params, PF firewall, multicast routes, pmset — run with sudo</span>
    </div>
    <div class="file-item">
      <span class="file-name">$(basename $FIX_FFMPEG_FILE)</span>
      <span class="file-desc">Recommended corrected FFmpeg commands (print only — run manually)</span>
    </div>
    <div class="file-item">
      <span class="file-name">$(basename $DIAG_DUPLEX_FILE)</span>
      <span class="file-desc">Half-duplex investigation: live counter trend + switch/cable checklist — run with sudo</span>
    </div>
  </div>

  <div id="processes" class="report-section">
    <h2 class="section-title">FFmpeg Processes</h2>
    <div class="proc-grid">${PROC_CARDS_HTML:-<p style="color:var(--muted);font-family:var(--mono);font-size:13px">No processes detected.</p>}</div>
  </div>

  <div id="topology" class="topo-card">
    <div class="topo-title">Network Topology — Internal Multicast Bus</div>
    <svg viewBox="0 0 700 220" xmlns="http://www.w3.org/2000/svg" style="width:100%;max-width:700px">
      <defs>
        <marker id="arr"  markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto"><polygon points="0 0,8 3,0 6" fill="#6366f1"/></marker>
        <marker id="arrg" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto"><polygon points="0 0,8 3,0 6" fill="#10b981"/></marker>
        <marker id="arrr" markerWidth="8" markerHeight="6" refX="8" refY="3" orient="auto"><polygon points="0 0,8 3,0 6" fill="#ef4444"/></marker>
      </defs>
      <rect x="10"  y="85"  width="110" height="50" rx="8" fill="#1e1b4b" stroke="#6366f1" stroke-width="2"/>
      <text x="65"  y="107" text-anchor="middle" fill="#a5b4fc" font-size="11" font-family="monospace" font-weight="bold">DeckLink</text>
      <text x="65"  y="122" text-anchor="middle" fill="#6366f1" font-size="10" font-family="monospace">SDI Input</text>
      <rect x="175" y="75"  width="130" height="70" rx="8" fill="#1e1b4b" stroke="#10b981" stroke-width="2"/>
      <text x="240" y="100" text-anchor="middle" fill="#6ee7b7" font-size="11" font-family="monospace" font-weight="bold">FFmpeg Sender</text>
      <text x="240" y="116" text-anchor="middle" fill="#10b981" font-size="9"  font-family="monospace">h264_videotoolbox</text>
      <text x="240" y="131" text-anchor="middle" fill="#10b981" font-size="9"  font-family="monospace">localaddr=127.0.0.1</text>
      <line x1="120" y1="110" x2="173" y2="110" stroke="#6366f1" stroke-width="2" marker-end="url(#arr)"/>
      <rect x="355" y="85"  width="110" height="50" rx="8" fill="#1e1b4b" stroke="#6366f1" stroke-width="2" stroke-dasharray="5,3"/>
      <text x="410" y="107" text-anchor="middle" fill="#a5b4fc" font-size="11" font-family="monospace" font-weight="bold">lo0</text>
      <text x="410" y="122" text-anchor="middle" fill="#6366f1" font-size="9"  font-family="monospace">multicast bus</text>
      <line x1="305" y1="110" x2="353" y2="110" stroke="#10b981" stroke-width="2" marker-end="url(#arrg)"/>
      <rect x="520" y="30"  width="130" height="50" rx="8" fill="#1e1b4b" stroke="#10b981" stroke-width="2"/>
      <text x="585" y="52"  text-anchor="middle" fill="#6ee7b7" font-size="11" font-family="monospace" font-weight="bold">FFmpeg</text>
      <text x="585" y="67"  text-anchor="middle" fill="#10b981" font-size="9"  font-family="monospace">→ YouTube RTMP</text>
      <rect x="520" y="140" width="130" height="50" rx="8" fill="#1e1b4b" stroke="#10b981" stroke-width="2"/>
      <text x="585" y="162" text-anchor="middle" fill="#6ee7b7" font-size="11" font-family="monospace" font-weight="bold">FFmpeg</text>
      <text x="585" y="177" text-anchor="middle" fill="#10b981" font-size="9"  font-family="monospace">→ WebRTC</text>
      <line x1="465" y1="100" x2="518" y2="68"  stroke="#10b981" stroke-width="1.5" marker-end="url(#arrg)"/>
      <line x1="465" y1="118" x2="518" y2="152" stroke="#10b981" stroke-width="1.5" marker-end="url(#arrg)"/>
      <line x1="240" y1="145" x2="240" y2="185" stroke="#ef4444" stroke-width="1.5" stroke-dasharray="4,3" marker-end="url(#arrr)"/>
      <rect x="175" y="185" width="130" height="30" rx="6" fill="#450a0a" stroke="#ef4444" stroke-width="1.5"/>
      <text x="240" y="204" text-anchor="middle" fill="#fca5a5" font-size="10" font-family="monospace">🚫 ${OUTBOUND_IFACE} — BLOCKED</text>
    </svg>
  </div>

  <div id="bandwidth" class="bw-card">
    <div class="bw-title">Bitrate Utilisation</div>
    <div class="bw-nums">
      <span>Requested: <strong>${REQUESTED_TOTAL} kbit/s</strong></span>
      <span>lo0 actual: <strong>${LO_MBPS} Mbit/s</strong></span>
      <span>${OUTBOUND_IFACE} (leak): <strong style="color:var(--red)">${IF_MBPS} Mbit/s</strong></span>
      <span>Utilisation: <strong style="color:${BAR_COLOR}">${RATIO}%</strong></span>
    </div>
    <div class="bw-track"><div class="bw-fill" style="width:${BAR_PCT}%;background:${BAR_COLOR}"></div></div>
    <div class="bw-labels"><span>0%</span><span>50%</span><span>100%</span></div>
  </div>

  <div id="sender">$(build_section_html sender "Sender Command Analysis")</div>
  <div id="network">$(build_section_html network "Network Interface Health")</div>
  <div id="routing">$(build_section_html routing "Multicast Routing")</div>
  <div id="firewall">$(build_section_html firewall "PF Firewall")</div>
  <div id="kernel">$(build_section_html kernel "Kernel Parameters &amp; UDP Health")</div>
  <div id="resources">
    $(build_section_html resources "System Resources")
    $(build_section_html power "Power Management")
  </div>
  <div id="leak">
    $(build_section_html bandwidth "Bandwidth Measurement")
    $(build_section_html leak "Multicast Leak Test")
  </div>

  <div id="recommended" class="rec-card">
    <div class="rec-title">Recommended FFmpeg Sender Command (h264_videotoolbox)</div>
    <div class="rec-desc">Built from detected configuration. Uses Apple GPU encoder for lower CPU overhead. See fix_ffmpeg_commands script for all three commands including receivers.</div>
    <pre class="rec-code">${REC_CMD_ESC}</pre>
  </div>

  <div id="fixes" class="fixes-card">
    <div class="fixes-title">All Fix Commands — run in order</div>
    ${FIX_HTML:-<p style="color:var(--muted);font-family:var(--mono);font-size:12px">No fixes needed. ✅</p>}
  </div>

</main>
</div>
</body>
</html>
HTMLEOF

# =============================================================================
# ── FINAL TERMINAL SUMMARY ────────────────────────────────────────────────────
# =============================================================================

echo
echo "${BOLD}${CYAN}╔══════════════════════════════════════════════════════════════╗${RESET}"
echo "${BOLD}${CYAN}║  Generated Files                                             ║${RESET}"
echo "${BOLD}${CYAN}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo
echo "  ${GREEN}${BOLD}$(basename $REPORT_FILE)${RESET}"
echo "  ${DIM}  Full diagnostic report — open in browser${RESET}"
echo
echo "  ${GREEN}${BOLD}$(basename $FIX_SYS_FILE)${RESET}"
echo "  ${DIM}  Kernel params + PF firewall + routing + pmset — run: sudo ./$(basename $FIX_SYS_FILE)${RESET}"
echo
echo "  ${GREEN}${BOLD}$(basename $FIX_FFMPEG_FILE)${RESET}"
echo "  ${DIM}  Corrected FFmpeg commands (print only) — run: ./$(basename $FIX_FFMPEG_FILE)${RESET}"
echo
echo "  ${GREEN}${BOLD}$(basename $DIAG_DUPLEX_FILE)${RESET}"
echo "  ${DIM}  Half-duplex investigation tool — run: sudo ./$(basename $DIAG_DUPLEX_FILE)${RESET}"
echo
echo "  ${DIM}All files saved to: ${SCRIPT_DIR}${RESET}"
echo
echo "  ${CYAN}Next step: sudo ./$(basename $FIX_SYS_FILE)   then re-run this script to verify${RESET}"
echo
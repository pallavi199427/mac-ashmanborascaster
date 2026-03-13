#!/usr/bin/env bash
###############################################################################
# yt_common.sh — Shared utility functions for YT appliance services
#
# Source this file after setting:
#   SERVICE_NAME   — e.g. "yt-ingest", "yt-uplink"
#   LOG_DIR        — log directory path
#   EVENTS_LOG     — events JSONL path
#   FFMPEG_LOG     — ffmpeg log path
#   STATUS_JSON    — status JSON path
#   METRICS_JSON   — metrics JSON path
#   PROGRESS_FILE  — ffmpeg progress path
#   SDI_SIGNAL_FILE — sdi signal state file
#   LOCK_FILE      — singleton lock file path
#   LOCK_PGREP_PATTERN — pgrep pattern for orphan cleanup
#
# Optional (set before sourcing if needed):
#   ALERTS_DIR, ALERT_SCRIPT
###############################################################################

# ---------- Helpers ----------
ts_utc() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

json_escape() {
  local s="${1}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '%s' "${s}"
}

atomic_write() {
  local path="$1"
  local tmp="${path}.tmp"
  cat > "${tmp}"
  mv "${tmp}" "${path}"
}

log_event() {
  local level="$1"; shift
  local event="$1"; shift
  local message="$1"; shift
  local extra="${1:-}"

  local t msg line
  t="$(ts_utc)"
  msg="$(json_escape "${message}")"

  line="{\"ts\":\"${t}\",\"level\":\"${level}\",\"event\":\"${event}\",\"message\":\"${msg}\",\"service\":\"$(json_escape "${SERVICE_NAME}")\",\"mode\":\"$(json_escape "${MODE}")\",\"device\":\"$(json_escape "${DECKLINK_DEVICE:-}")\",\"format\":\"$(json_escape "${FORMAT_CODE:-}")\""
  [[ -n "${extra}" ]] && line="${line},${extra}"
  line="${line}}"

  echo "${line}" >> "${EVENTS_LOG}"
}

write_status() {
  local state="$1"; shift
  local detail="${1:-{}}"
  local t
  t="$(ts_utc)"

  atomic_write "${STATUS_JSON}" <<EOF
{"ts":"${t}","state":"$(json_escape "${state}")","mode":"$(json_escape "${MODE}")","service":"$(json_escape "${SERVICE_NAME}")","detail":${detail}}
EOF
}

run_alert() {
  local ev="$1"; shift
  local detail="${1:-{}}"

  if [[ -x "${ALERT_SCRIPT:-}" ]]; then
    # shellcheck disable=SC2034
    ALERT_TS="$(ts_utc)"
    ALERT_EVENT="${ev}"
    ALERT_MODE="${MODE}"
    ALERT_DEVICE="${DECKLINK_DEVICE:-}"
    ALERT_FORMAT="${FORMAT_CODE:-}"
    ALERT_DETAIL="${detail}"

    ( "${ALERT_SCRIPT}" "${ev}" "${detail}" >> "${LOG_DIR}/alerts.log" 2>&1 ) || true
  fi
}

require_bin() {
  command -v "$1" >/dev/null 2>&1 || {
    log_event "ERROR" "missing_binary" "Required binary not found: $1" "\"bin\":\"$(json_escape "$1")\""
    run_alert "missing_binary" "{\"bin\":\"$(json_escape "$1")\"}"
    exit 3
  }
}

# ---------- Privilege helpers ----------
SUDO=""
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

# ---------- Log size management ----------
cleanup_logs_by_size() {
  local max_events_mb="${MAX_EVENTS_LOG_MB:-200}"
  local max_ffmpeg_mb="${MAX_FFMPEG_LOG_MB:-500}"

  if [[ -f "${EVENTS_LOG}" ]]; then
    local sz
    sz=$(du -m "${EVENTS_LOG}" | awk '{print $1}')
    if [[ "${sz}" -gt "${max_events_mb}" ]]; then
      tail -n 200000 "${EVENTS_LOG}" > "${EVENTS_LOG}.tmp" && mv "${EVENTS_LOG}.tmp" "${EVENTS_LOG}"
      log_event "WARN" "log_trim" "Trimmed events log (safety)" "\"max_mb\":${max_events_mb}"
    fi
  fi

  if [[ -f "${FFMPEG_LOG}" ]]; then
    local sz
    sz=$(du -m "${FFMPEG_LOG}" | awk '{print $1}')
    if [[ "${sz}" -gt "${max_ffmpeg_mb}" ]]; then
      tail -n 200000 "${FFMPEG_LOG}" > "${FFMPEG_LOG}.tmp" && mv "${FFMPEG_LOG}.tmp" "${FFMPEG_LOG}"
      log_event "WARN" "log_trim" "Trimmed ffmpeg log (safety)" "\"max_mb\":${max_ffmpeg_mb}"
    fi
  fi
}

# ---------- Singleton lock ----------
acquire_lock() {
  if [[ -f "${LOCK_FILE}" ]]; then
    local OLD_PID
    OLD_PID="$(cat "${LOCK_FILE}" 2>/dev/null || true)"
    if [[ -n "${OLD_PID}" ]] && kill -0 "${OLD_PID}" 2>/dev/null; then
      echo "Killing previous ${SERVICE_NAME} instance (PID ${OLD_PID})..." >&2
      kill -TERM -- -"${OLD_PID}" 2>/dev/null || kill -TERM "${OLD_PID}" 2>/dev/null || true
      sleep 1
      kill -KILL -- -"${OLD_PID}" 2>/dev/null || kill -KILL "${OLD_PID}" 2>/dev/null || true
      sleep 0.5
    fi
    if [[ -n "${LOCK_PGREP_PATTERN:-}" ]]; then
      local _opid
      for _opid in $(/usr/bin/pgrep -f "${LOCK_PGREP_PATTERN}" 2>/dev/null || true); do
        [[ "${_opid}" == "$$" ]] && continue
        kill -KILL "${_opid}" 2>/dev/null || true
      done
      sleep 0.5
    fi
  fi
  echo $$ > "${LOCK_FILE}"
}

# ---------- Cleanup trap ----------
_CLEANUP_DONE=0
_MAIN_FFMPEG_PID=""
_MAIN_TAIL_PID=""
_MAIN_MONITOR_PID=""
_MAIN_METRICS_PID=""
_MAIN_STALL_PID=""
_MAIN_MONITOR_TAIL_PID=""

_cleanup() {
  [[ "${_CLEANUP_DONE}" == "1" ]] && return
  _CLEANUP_DONE=1
  trap '' SIGTERM SIGINT EXIT
  declare -f kill_running_ffmpeg >/dev/null 2>&1 && kill_running_ffmpeg 2>/dev/null || true
  local _p
  for _p in "${_MAIN_FFMPEG_PID}" "${_MAIN_TAIL_PID}" "${_MAIN_MONITOR_TAIL_PID}" \
             "${_MAIN_MONITOR_PID}" "${_MAIN_METRICS_PID}" "${_MAIN_STALL_PID}"; do
    [[ -n "${_p}" ]] && kill "${_p}" 2>/dev/null || true
  done
  sleep 0.3
  for _p in "${_MAIN_FFMPEG_PID}" "${_MAIN_TAIL_PID}" "${_MAIN_MONITOR_TAIL_PID}" \
             "${_MAIN_MONITOR_PID}" "${_MAIN_METRICS_PID}" "${_MAIN_STALL_PID}"; do
    [[ -n "${_p}" ]] && kill -KILL "${_p}" 2>/dev/null || true
  done
  kill -TERM -- -$$ 2>/dev/null || true
  sleep 0.2
  kill -KILL -- -$$ 2>/dev/null || true
  rm -f "${LOCK_FILE}" 2>/dev/null || true
}

install_cleanup_trap() {
  trap '_cleanup' SIGTERM SIGINT EXIT
}

# ---------- Audio ----------
audio_args() {
  local codec="${AUDIO_CODEC:-aac}"

  if [[ "${codec}" == "libfdk_aac" ]]; then
    printf '%s' "-c:a libfdk_aac -ar ${AUDIO_RATE} -ac ${AUDIO_CHANNELS} -vbr ${FDK_VBR_MODE}"
    return 0
  fi

  local abr="${AUDIO_BITRATE_K:-160k}"
  printf '%s' "-c:a aac -b:a ${abr} -ar ${AUDIO_RATE} -ac ${AUDIO_CHANNELS}"
}

# ---------- Video filter ----------
build_live_vf() {
  local res="${OUTPUT_RESOLUTION:-1920x1080}"
  local wh="${res/x/:}"
  printf '%s' "bwdif=mode=1:parity=tff:deint=all,fps=25,scale=${wh}:flags=lanczos,format=yuv420p"
}

# ---------- SDI Signal Detection ----------
probe_sdi_signal() {
  local probe_out_file="${LOG_DIR}/probe_out.$$"

  "${FFMPEG_BIN}" -hide_banner -loglevel info \
      -f decklink -video_input "${VIDEO_INPUT}" -audio_input "${AUDIO_INPUT}" \
      -i "${DECKLINK_DEVICE}" \
      -t 1 -f null - >"${probe_out_file}" 2>&1 &
  local probe_pid=$!

  local i
  for i in 1 2 3 4 5; do
    if ! kill -0 "${probe_pid}" 2>/dev/null; then
      break
    fi
    sleep 1
  done

  if kill -0 "${probe_pid}" 2>/dev/null; then
    kill -KILL "${probe_pid}" 2>/dev/null || true
    wait "${probe_pid}" 2>/dev/null || true
    rm -f "${probe_out_file}"
    return 1
  fi

  wait "${probe_pid}" 2>/dev/null || true
  local out
  out="$(cat "${probe_out_file}" 2>/dev/null || true)"
  rm -f "${probe_out_file}"

  if echo "${out}" | grep -qiE "No input signal detected|No signal|Cannot Autodetect input"; then
    return 1
  fi
  if echo "${out}" | grep -q "Input #0, decklink"; then
    return 0
  fi

  return 1
}

# ---------- Kill FFmpeg ----------
kill_running_ffmpeg() {
  /usr/bin/pkill -TERM -f "${FFMPEG_BIN}.*${DECKLINK_DEVICE:-__no_device__}" >/dev/null 2>&1 || true
  /usr/bin/pkill -TERM -f "${FFMPEG_BIN}.*color=c=${STANDBY_BG_COLOR:-__no_color__}" >/dev/null 2>&1 || true
  sleep 0.5
  /usr/bin/pkill -KILL -f "${FFMPEG_BIN}.*${DECKLINK_DEVICE:-__no_device__}" >/dev/null 2>&1 || true
  /usr/bin/pkill -KILL -f "${FFMPEG_BIN}.*color=c=${STANDBY_BG_COLOR:-__no_color__}" >/dev/null 2>&1 || true
  sleep 1
}

# ---------- Metrics loop ----------
metrics_loop() {
  while true; do
    sleep "${METRICS_INTERVAL}"

    local out_time_ms frame fps speed enc_bitrate
    out_time_ms="$(awk -F= '$1=="out_time_ms" {v=$2} END{print v}' "${PROGRESS_FILE}" 2>/dev/null || true)"
    frame="$(awk -F= '$1=="frame" {v=$2} END{print v}' "${PROGRESS_FILE}" 2>/dev/null || true)"
    fps="$(awk -F= '$1=="fps" {v=$2} END{print v}' "${PROGRESS_FILE}" 2>/dev/null || true)"
    speed="$(awk -F= '$1=="speed" {v=$2} END{print v}' "${PROGRESS_FILE}" 2>/dev/null || true)"
    enc_bitrate="$(awk -F= '$1=="bitrate" {v=$2} END{print v}' "${PROGRESS_FILE}" 2>/dev/null || true)"

    [[ -z "${out_time_ms}" ]] && out_time_ms="0"
    [[ -z "${frame}" ]] && frame="0"
    [[ -z "${fps}" ]] && fps="0"
    [[ -z "${speed}" ]] && speed="0"
    [[ -z "${enc_bitrate}" ]] && enc_bitrate="0"

    local drop dup
    drop="$(tail -n 250 "${FFMPEG_LOG}" 2>/dev/null | grep -Eo 'drop=[0-9]+' | tail -n 1 | cut -d= -f2 || true)"
    dup="$(tail -n 250 "${FFMPEG_LOG}" 2>/dev/null | grep -Eo 'dup=[0-9]+' | tail -n 1 | cut -d= -f2 || true)"
    [[ -z "${drop}" ]] && drop="0"
    [[ -z "${dup}" ]] && dup="0"

    local pid
    pid="$(/usr/bin/pgrep -n -f "${FFMPEG_BIN}.*-progress ${PROGRESS_FILE}" 2>/dev/null || true)"
    [[ -z "${pid}" ]] && pid="0"

    local ff
    ff="{\"pid\":${pid},\"out_time_ms\":${out_time_ms},\"speed\":\"$(json_escape "${speed}")\",\"fps\":${fps},\"frame\":${frame},\"drop\":${drop},\"dup\":${dup},\"enc_bitrate\":\"$(json_escape "${enc_bitrate}")\"}"

    write_metrics_snapshot "running" "${ff}"
  done
}

# ---------- Output stall watchdog ----------
watch_output_stall() {
  local last_ms="0"
  local last_change
  last_change="$(date +%s)"

  while true; do
    sleep "${STALL_CHECK_INTERVAL}"

    [[ -f "${PROGRESS_FILE}" ]] || continue

    local ms
    ms="$(awk -F= '$1=="out_time_ms" {v=$2} END{print v}' "${PROGRESS_FILE}" 2>/dev/null || true)"
    [[ -n "${ms}" ]] || continue

    if [[ "${ms}" != "${last_ms}" ]]; then
      last_ms="${ms}"
      last_change="$(date +%s)"
      continue
    fi

    local now stalled_for
    now="$(date +%s)"
    stalled_for=$(( now - last_change ))

    if [[ "${stalled_for}" -ge "${STALL_TIMEOUT_SECONDS}" ]]; then
      log_event "ERROR" "output_stalled" "Output progress stalled; restarting FFmpeg" "\"stalled_for\":${stalled_for},\"out_time_ms\":${last_ms}"
      run_alert "output_stalled" "{\"stalled_for\":${stalled_for},\"out_time_ms\":${last_ms}}"
      write_status "output_stalled" "{\"stalled_for\":${stalled_for},\"out_time_ms\":${last_ms}}"
      write_metrics_snapshot "output_stalled" "{\"out_time_ms\":${last_ms},\"stalled_for\":${stalled_for}}"
      kill_running_ffmpeg
      exit 0
    fi
  done
}

# ---------- FFmpeg runner ----------
# run_ffmpeg_mode MODE BUILD_CMD_FUNC [MONITOR_NOSIGNAL]
#   MODE             — "live" or "standby"
#   BUILD_CMD_FUNC   — function name that prints the ffmpeg command
#   MONITOR_NOSIGNAL — "true" to enable no-signal monitoring (live mode)
run_ffmpeg_mode() {
  local mode="$1"
  local build_cmd_func="$2"
  local monitor_nosignal="${3:-false}"
  MODE="${mode}"
  TOTAL_MODE_STARTS=$((TOTAL_MODE_STARTS+1))
  START_EPOCH="$(date +%s)"

  cleanup_logs_by_size

  log_event "INFO" "mode_start" "Starting mode ${mode}" "\"mode\":\"$(json_escape "${mode}")\""
  run_alert "mode_start" "{\"mode\":\"$(json_escape "${mode}")\"}"
  write_status "${mode}_starting" "{\"mode\":\"$(json_escape "${mode}")\"}"

  rm -f "${PROGRESS_FILE}" >/dev/null 2>&1 || true

  local stall_pid="" metrics_pid_local=""

  if [[ "${ENABLE_OUTPUT_STALL_WATCHDOG:-false}" == "true" ]]; then
    watch_output_stall &
    stall_pid="$!"
    _MAIN_STALL_PID="${stall_pid}"
    log_event "INFO" "stall_watchdog_start" "Started output stall watchdog" "\"pid\":${stall_pid}"
  fi

  metrics_loop &
  metrics_pid_local="$!"
  _MAIN_METRICS_PID="${metrics_pid_local}"

  local rc
  local ffmpeg_pid=""
  local nosignal_file="${LOG_DIR}/nosignal.$$"
  local monitor_pid="" tail_pid=""
  local monitor_tail_pid_file="${LOG_DIR}/monitor_tail.$$"

  touch "${FFMPEG_LOG}"

  set +e

  # Launch ffmpeg
  bash -c "$("${build_cmd_func}")" >> "${FFMPEG_LOG}" 2>&1 &
  ffmpeg_pid=$!
  _MAIN_FFMPEG_PID="${ffmpeg_pid}"

  # Tail ffmpeg log for visibility
  tail -n +1 -f "${FFMPEG_LOG}" &
  tail_pid=$!
  _MAIN_TAIL_PID="${tail_pid}"

  if [[ "${monitor_nosignal}" == "true" ]]; then
    # Monitor with no-signal detection
    rm -f "${nosignal_file}" "${monitor_tail_pid_file}"
    (
      tail -n +1 -f "${FFMPEG_LOG}" 2>/dev/null &
      echo $! > "${monitor_tail_pid_file}"
      wait $!
    ) | while IFS= read -r line; do
      local short
      short="$(echo "${line}" | tail -c 500 | tr -d '\r')"
      write_status "running" "{\"mode\":\"$(json_escape "${mode}")\"${CURRENT_BITRATE:+,\"bitrate\":\"${CURRENT_BITRATE}\"},\"ffmpeg\":\"$(json_escape "${short}")\"}"

      if echo "${line}" | grep -qiE "No input signal detected|No signal|Cannot Autodetect input"; then
        echo "1" >> "${nosignal_file}"
        echo "0" > "${SDI_SIGNAL_FILE}"
        local cnt
        cnt=$(wc -l < "${nosignal_file}" 2>/dev/null || echo 0)
        log_event "WARN" "no_signal" "SDI input signal missing" "\"count\":${cnt}"
        run_alert "no_signal" "{\"count\":${cnt}}"
        if [[ "${cnt}" -ge "${MAX_NO_SIGNAL_LINES}" ]]; then
          log_event "ERROR" "no_signal_restart" "Too many no-signal messages; restarting FFmpeg"
          run_alert "no_signal_restart" "{\"count\":${cnt}}"
          kill "${ffmpeg_pid}" 2>/dev/null || true
          break
        fi
      else
        if [[ -s "${nosignal_file}" ]]; then
          echo "1" > "${SDI_SIGNAL_FILE}"
        fi
        : > "${nosignal_file}" 2>/dev/null || true
      fi
    done &
    monitor_pid=$!
    _MAIN_MONITOR_PID="${monitor_pid}"
  else
    # Simple status monitor (standby or uplink — no SDI signal checking)
    rm -f "${monitor_tail_pid_file}"
    (
      tail -n +1 -f "${FFMPEG_LOG}" 2>/dev/null &
      echo $! > "${monitor_tail_pid_file}"
      wait $!
    ) | while IFS= read -r line; do
      local short
      short="$(echo "${line}" | tail -c 500 | tr -d '\r')"
      write_status "running" "{\"mode\":\"$(json_escape "${mode}")\"${CURRENT_BITRATE:+,\"bitrate\":\"${CURRENT_BITRATE}\"},\"ffmpeg\":\"$(json_escape "${short}")\"}"
    done &
    monitor_pid=$!
    _MAIN_MONITOR_PID="${monitor_pid}"
  fi

  # Wait for ffmpeg — reliable exit code
  wait "${ffmpeg_pid}" 2>/dev/null
  rc=$?

  # Kill monitor's internal tail PID, then monitor, then our tail
  local _mtail_pid
  _mtail_pid="$(cat "${monitor_tail_pid_file}" 2>/dev/null || true)"
  _MAIN_MONITOR_TAIL_PID="${_mtail_pid}"
  kill "${tail_pid}" 2>/dev/null || true
  kill "${_mtail_pid}" 2>/dev/null || true
  kill "${monitor_pid}" 2>/dev/null || true
  wait "${tail_pid}" 2>/dev/null || true
  wait "${_mtail_pid}" 2>/dev/null || true
  wait "${monitor_pid}" 2>/dev/null || true
  rm -f "${nosignal_file}" "${monitor_tail_pid_file}"

  set -e

  [[ -n "${metrics_pid_local}" ]] && kill "${metrics_pid_local}" >/dev/null 2>&1 || true
  [[ -n "${stall_pid}" ]] && kill "${stall_pid}" >/dev/null 2>&1 || true

  TOTAL_FFMPEG_EXITS=$((TOTAL_FFMPEG_EXITS+1))
  LAST_EXIT_RC="${rc}"
  write_metrics_snapshot "ffmpeg_exited" "{\"rc\":${rc}}"

  return "${rc}"
}

# ---------- Supervisor loop ----------
# supervisor_loop BUILD_LIVE_CMD_FUNC BUILD_STANDBY_CMD_FUNC
#   Both args are function names that print the ffmpeg command string
supervisor_loop() {
  local build_live_func="$1"
  local build_standby_func="$2"

  CONSEC_FAILS=0
  BACKOFF="${RESTART_BACKOFF_SECONDS}"
  OK_COUNT=0
  BAD_COUNT=0

  if [[ "${ENABLE_STANDBY}" == "true" ]]; then
    MODE="standby"
  else
    MODE="live"
  fi

  log_event "INFO" "supervisor_start" "Supervisor loop started"
  run_alert "supervisor_start" "{}"
  write_status "supervising" "{\"mode\":\"${MODE}\"}"
  write_metrics_snapshot "supervising" "{}"

  while true; do
    if probe_sdi_signal; then
      PROBE_OK_COUNT=$((PROBE_OK_COUNT+1))
      OK_COUNT=$((OK_COUNT+1))
      BAD_COUNT=0
      echo "1" > "${SDI_SIGNAL_FILE}"
    else
      PROBE_BAD_COUNT=$((PROBE_BAD_COUNT+1))
      BAD_COUNT=$((BAD_COUNT+1))
      OK_COUNT=0
      echo "0" > "${SDI_SIGNAL_FILE}"
    fi

    if [[ "${ENABLE_STANDBY}" == "true" ]]; then
      if [[ "${MODE}" != "standby" && "${BAD_COUNT}" -ge "${SWITCH_TO_STANDBY_AFTER}" ]]; then
        log_event "WARN" "switch_to_standby" "Switching to standby (signal missing)" "\"bad\":${BAD_COUNT}"
        run_alert "switch_to_standby" "{\"bad\":${BAD_COUNT}}"
        kill_running_ffmpeg
        MODE="standby"
      fi

      if [[ "${MODE}" != "live" && "${OK_COUNT}" -ge "${SWITCH_TO_LIVE_AFTER}" ]]; then
        log_event "INFO" "switch_to_live" "Switching to live (signal present)" "\"ok\":${OK_COUNT}"
        run_alert "switch_to_live" "{\"ok\":${OK_COUNT}}"
        kill_running_ffmpeg
        MODE="live"
      fi
    else
      MODE="live"
    fi

    local build_func monitor_nosignal
    if [[ "${MODE}" == "live" ]]; then
      build_func="${build_live_func}"
      monitor_nosignal="true"
    else
      build_func="${build_standby_func}"
      monitor_nosignal="false"
    fi

    set +e
    run_ffmpeg_mode "${MODE}" "${build_func}" "${monitor_nosignal}"
    local rc=$?
    set -e

    if [[ "${rc}" -eq 0 ]]; then
      log_event "WARN" "ffmpeg_exit_normal" "FFmpeg exited normally; restarting" "\"rc\":${rc}"
      run_alert "ffmpeg_exit_normal" "{\"rc\":${rc}}"
      CONSEC_FAILS=0
      BACKOFF="${RESTART_BACKOFF_SECONDS}"
      # Call on_ffmpeg_success if defined (e.g. uplink resets bitrate)
      declare -f on_ffmpeg_success >/dev/null 2>&1 && on_ffmpeg_success
      sleep 1
    else
      CONSEC_FAILS=$((CONSEC_FAILS+1))
      log_event "ERROR" "ffmpeg_exit_error" "FFmpeg exited with error" "\"rc\":${rc},\"consecutive_failures\":${CONSEC_FAILS}"
      run_alert "ffmpeg_exit_error" "{\"rc\":${rc},\"consecutive_failures\":${CONSEC_FAILS}}"

      # Call on_ffmpeg_failure if defined (e.g. uplink downgrades bitrate)
      declare -f on_ffmpeg_failure >/dev/null 2>&1 && on_ffmpeg_failure

      BACKOFF=$(( BACKOFF * 2 ))
      [[ "${BACKOFF}" -gt "${RESTART_BACKOFF_MAX_SECONDS}" ]] && BACKOFF="${RESTART_BACKOFF_MAX_SECONDS}"

      write_status "backoff" "{\"seconds\":${BACKOFF},\"mode\":\"${MODE}\",\"rc\":${rc}}"
      write_metrics_snapshot "backoff" "{\"seconds\":${BACKOFF},\"rc\":${rc}}"
      log_event "INFO" "restart_backoff" "Restarting after backoff" "\"seconds\":${BACKOFF}"
      sleep "${BACKOFF}"
    fi

    sleep "${PROBE_INTERVAL}"
  done
}

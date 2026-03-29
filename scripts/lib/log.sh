#!/usr/bin/env bash

: "${LOG_TS_FORMAT:=%Y-%m-%d %H:%M:%S}"
: "${LOG_LEVEL_WIDTH:=5}"
: "${LOG_COLOR_MODE:=auto}"

log__detect_color_support() {
  case "$LOG_COLOR_MODE" in
    always)
      LOG_COLOR_ENABLED=1
      return
      ;;
    never)
      LOG_COLOR_ENABLED=0
      return
      ;;
  esac

  if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    LOG_COLOR_ENABLED=1
  else
    LOG_COLOR_ENABLED=0
  fi
}

[[ -n "${LOG_COLOR_ENABLED:-}" ]] || log__detect_color_support

LOG_COLOR_RESET=$'\033[0m'
LOG_COLOR_INFO=$'\033[34m'
LOG_COLOR_SUCCESS=$'\033[32m'
LOG_COLOR_WARN=$'\033[33m'
LOG_COLOR_ERROR=$'\033[31m'
LOG_COLOR_SECTION=$'\033[35m'

log__emit() {
  local level="$1"
  local color="$2"
  shift 2 || true
  local message="$*"
  local ts
  local padded_level

  ts="$(date +"$LOG_TS_FORMAT")"
  printf -v padded_level '%-*s' "$LOG_LEVEL_WIDTH" "$level"

  if [[ ${LOG_COLOR_ENABLED:-0} -eq 1 && -n "$color" ]]; then
    printf '%b[%s] %s  %s%b\n' "$color" "$ts" "$padded_level" "$message" "$LOG_COLOR_RESET"
  else
    printf '[%s] %s  %s\n' "$ts" "$padded_level" "$message"
  fi
}

log_info() {
  log__emit "INFO" "$LOG_COLOR_INFO" "$@"
}

log_success() {
  log__emit "DONE" "$LOG_COLOR_SUCCESS" "$@"
}

log_warn() {
  log__emit "WARN" "$LOG_COLOR_WARN" "$@"
}

log_error() {
  log__emit "ERROR" "$LOG_COLOR_ERROR" "$@"
}

log_section() {
  local title="$*"
  local line
  line="== ${title:-Section} =="
  if [[ ${LOG_COLOR_ENABLED:-0} -eq 1 ]]; then
    printf '%b%s%b\n' "$LOG_COLOR_SECTION" "$line" "$LOG_COLOR_RESET"
  else
    printf '%s\n' "$line"
  fi
}

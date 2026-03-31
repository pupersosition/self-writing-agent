require_command() {
  local cmd="$1"
  local hint="${2:-}"

  command -v "$cmd" >/dev/null 2>&1 || {
    if [[ -n "$hint" ]]; then
      echo "$hint" >&2
    else
      echo "Missing required command: $cmd" >&2
    fi
    exit 1
  }
}

ensure_prerequisites() {
  require_command curl
  require_command jq
  require_command codex
  require_command git
  require_command gh
  require_command perl "Missing required command: perl (needed for PR summary parsing)."
  [[ -n "${LINEAR_API_KEY:-}" ]] || {
    echo "LINEAR_API_KEY is required" >&2
    exit 1
  }

  mkdir -p "$LOG_DIR" "$ISSUE_STATE_DIR"
}

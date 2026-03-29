require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

ensure_prerequisites() {
  require_command curl
  require_command jq
  require_command codex
  require_command git
  require_command gh
  [[ -n "${LINEAR_API_KEY:-}" ]] || {
    echo "LINEAR_API_KEY is required" >&2
    exit 1
  }

  mkdir -p "$LOG_DIR" "$ISSUE_STATE_DIR"
}

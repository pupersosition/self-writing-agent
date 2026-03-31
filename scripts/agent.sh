#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$ROOT_DIR/.linear-agent"
LOG_DIR="$STATE_DIR/logs"
ISSUE_STATE_DIR="$STATE_DIR/issues"
LIB_DIR="$ROOT_DIR/scripts/lib"
AGENT_SCRIPT_PATH="$ROOT_DIR/scripts/agent.sh"
declare -a AGENT_ORIGINAL_ARGS=()
AGENT_COMMAND=""
AGENT_SOURCE_SYNC_STATUS=""

LINEAR_API_URL="${LINEAR_API_URL:-https://api.linear.app/graphql}"
LINEAR_PROJECT_NAME="${LINEAR_PROJECT_NAME:-Self writing agent}"
LINEAR_TEAM_NAME="${LINEAR_TEAM_NAME:-Self-writing-agent}"
LINEAR_TEAM_KEY="${LINEAR_TEAM_KEY:-SEL}"
LINEAR_BACKLOG_STATE_NAME="${LINEAR_BACKLOG_STATE_NAME:-Backlog}"
LINEAR_TODO_STATE_NAME="${LINEAR_TODO_STATE_NAME:-Todo}"
LINEAR_IN_PROGRESS_STATE_NAME="${LINEAR_IN_PROGRESS_STATE_NAME:-In Progress}"
LINEAR_IN_REVIEW_STATE_NAME="${LINEAR_IN_REVIEW_STATE_NAME:-In Review}"
LINEAR_DONE_STATE_NAME="${LINEAR_DONE_STATE_NAME:-Done}"
CODEX_MODEL="${CODEX_MODEL:-gpt-5-codex}"
GITHUB_REPO="${GITHUB_REPO:-pupersosition/self-writing-agent}"
GIT_REMOTE_NAME="${GIT_REMOTE_NAME:-origin}"
GIT_BASE_BRANCH="${GIT_BASE_BRANCH:-main}"

PROJECT_ID=""
TEAM_ID=""
BACKLOG_STATE_ID=""
TODO_STATE_ID=""
IN_PROGRESS_STATE_ID=""
IN_REVIEW_STATE_ID=""
DONE_STATE_ID=""

# shellcheck source=./lib/prereqs.sh
source "$LIB_DIR/prereqs.sh"
# shellcheck source=./lib/linear.sh
source "$LIB_DIR/linear.sh"
# shellcheck source=./lib/git.sh
source "$LIB_DIR/git.sh"
# shellcheck source=./lib/codex.sh
source "$LIB_DIR/codex.sh"
# shellcheck source=./lib/log.sh
source "$LIB_DIR/log.sh"

LAST_WAITING_IDENTIFIER=""
LAST_IDLE_REASON=""

log_issue_with_level() {
  local level="$1"
  local identifier="$2"
  shift 2 || true
  local message="$*"
  local prefix=""

  if [[ -n "$identifier" && "$identifier" != "unknown" ]]; then
    prefix="[$identifier] "
  fi

  case "$level" in
    info)
      log_info "${prefix}${message}"
      ;;
    success)
      log_success "${prefix}${message}"
      ;;
    warn)
      log_warn "${prefix}${message}"
      ;;
    error)
      log_error "${prefix}${message}"
      ;;
    *)
      log_info "${prefix}${message}"
      ;;
  esac
}

log_issue_info() {
  log_issue_with_level info "$@"
}

log_issue_success() {
  log_issue_with_level success "$@"
}

log_issue_warn() {
  log_issue_with_level warn "$@"
}

log_issue_error() {
  log_issue_with_level error "$@"
}

remember_idle_notice() {
  local reason="$1"
  local message="$2"

  if [[ "${LAST_IDLE_REASON:-}" == "$reason" ]]; then
    return
  fi

  log_info "$message"
  LAST_IDLE_REASON="$reason"
}

clear_idle_notice() {
  LAST_IDLE_REASON=""
}

remember_waiting_issue() {
  local identifier="$1"
  shift || true
  local message="${*:-Waiting for PR approval before marking Done.}"

  if [[ "${LAST_WAITING_IDENTIFIER:-}" == "$identifier" ]]; then
    return
  fi

  log_issue_info "$identifier" "$message"
  LAST_WAITING_IDENTIFIER="$identifier"
}

clear_waiting_issue_state() {
  LAST_WAITING_IDENTIFIER=""
}

sync_agent_state_after_merge() {
  local identifier="${1:-}"
  local pull_status

  if pull_latest_agent_source; then
    AGENT_SOURCE_SYNC_STATUS="updated"
    return 0
  fi

  pull_status="$?"
  if [[ "$pull_status" -eq 1 ]]; then
    AGENT_SOURCE_SYNC_STATUS="current"
    return 0
  fi

  AGENT_SOURCE_SYNC_STATUS="failed"
  log_issue_error "${identifier:-unknown}" "Agent detected merged issue but failed to sync latest source."
  return "$pull_status"
}

restart_agent_after_merge() {
  local identifier="${1:-}"

  case "${AGENT_SOURCE_SYNC_STATUS:-}" in
    updated)
      log_issue_success "${identifier:-unknown}" "Synced latest $GIT_BASE_BRANCH after merge."
      ;;
    current)
      log_issue_info "${identifier:-unknown}" "Agent source already current after merge."
      ;;
  esac

  if [[ "$AGENT_COMMAND" == "run-forever" ]]; then
    log_info "Agent source synced after PR merge; restarting to load current code."
    exec "$AGENT_SCRIPT_PATH" "${AGENT_ORIGINAL_ARGS[@]}"
    log_error "Agent source synced after PR merge but restart failed."
    return 1
  fi

  return 0
}


reconcile_in_review_issue() {
  local issue_json="$1"
  local identifier
  local issue_id
  local saved_state
  local pr_url
  local pr_number
  local commit_sha
  local pr_data
  local merged_at

  identifier="$(jq -r '.identifier' <<<"$issue_json")"
  issue_id="$(jq -r '.id' <<<"$issue_json")"
  saved_state="$(load_issue_state "$identifier" || true)"
  if [[ -z "$saved_state" ]]; then
    clear_waiting_issue_state
    return 1
  fi

  require_gh_auth
  pr_url="$(jq -r '.pr_url' <<<"$saved_state")"
  pr_number="$(jq -r '.pr_number' <<<"$saved_state")"
  pr_data="$(gh pr view "$pr_url" --repo "$GITHUB_REPO" --json state,mergedAt,url,reviewDecision,isDraft)"
  merged_at="$(jq -r '.mergedAt // empty' <<<"$pr_data")"

  if [[ -n "$merged_at" ]] && pr_has_approval "$pr_number"; then
    if ! sync_agent_state_after_merge "$identifier"; then
      issue_add_comment "$issue_id" "PR approved and merged: $(jq -r '.url' <<<"$pr_data"). The agent could not sync the latest \`$GIT_BASE_BRANCH\`, so the issue remains \`$LINEAR_IN_REVIEW_STATE_NAME\` for follow-up."
      log_issue_error "$identifier" "PR merged but syncing $GIT_BASE_BRANCH failed."
      clear_waiting_issue_state
      return 1
    fi

    issue_add_comment "$issue_id" "PR approved and merged: $(jq -r '.url' <<<"$pr_data"). Agent synced the latest \`$GIT_BASE_BRANCH\` and is marking the issue \`Done\`."
    issue_update_state "$issue_id" "$DONE_STATE_ID"
    log_issue_success "$identifier" "PR merged and issue marked \`$LINEAR_DONE_STATE_NAME\`."

    if ! restart_agent_after_merge "$identifier"; then
      issue_add_comment "$issue_id" "PR approved and merged, and the issue was marked \`Done\`, but the agent process failed to restart after syncing \`$GIT_BASE_BRANCH\`. Investigate the running process."
      clear_waiting_issue_state
      return 1
    fi

    clear_waiting_issue_state
    return 0
  fi

  remember_waiting_issue "$identifier" "PR awaiting approval before marking \`$LINEAR_DONE_STATE_NAME\`."
  return 1
}

process_issue() {
  local issue_json="$1"
  local issue_id
  local identifier
  local title
  local summary
  local issue_url
  local branch_name
  local pr_url
  local pr_number
  local commit_sha
  local latest_state
  local pull_status

  issue_id="$(jq -r '.id' <<<"$issue_json")"
  identifier="$(jq -r '.identifier' <<<"$issue_json")"
  title="$(jq -r '.title' <<<"$issue_json")"
  issue_url="$(jq -r '.url' <<<"$issue_json")"
  branch_name="$(issue_branch_name "$issue_json")"

  clear_idle_notice
  log_section "$identifier - $title"

  latest_state="$(issue_current_state_name "$issue_id")"
  if [[ "$latest_state" != "$LINEAR_TODO_STATE_NAME" && "$latest_state" != "$LINEAR_BACKLOG_STATE_NAME" ]]; then
    if [[ -z "$latest_state" ]]; then
      log_issue_warn "$identifier" "Skipping because Linear state is unknown."
    else
      log_issue_info "$identifier" "Skipping because state is '$latest_state'."
    fi
    return 0
  fi

  if ! preflight_for_issue; then
    issue_add_comment "$issue_id" "Agent could not start \`$identifier\` because the local git or GitHub CLI prerequisites are not satisfied."
    log_issue_error "$identifier" "Preflight checks failed; prerequisites missing."
    return 1
  fi

  pull_status=0
  if pull_latest_agent_source; then
    log_issue_info "$identifier" "Pulled latest \`$GIT_BASE_BRANCH\` before starting."
  else
    pull_status="$?"
    if [[ "$pull_status" -eq 1 ]]; then
      log_issue_info "$identifier" "Agent source already current before starting."
    else
      issue_add_comment "$issue_id" "Agent could not start \`$identifier\` because pulling the latest \`$GIT_BASE_BRANCH\` from remote \`$GIT_REMOTE_NAME\` failed. The issue remains in \`$LINEAR_TODO_STATE_NAME\` until the repository can pull cleanly."
      log_issue_error "$identifier" "Failed to pull latest \`$GIT_BASE_BRANCH\` before starting issue."
      return 1
    fi
  fi

  clear_issue_context "$identifier"
  issue_update_state "$issue_id" "$IN_PROGRESS_STATE_ID"
  issue_add_comment "$issue_id" "$(printf 'Agent started implementing `%s` on branch `%s` using model `%s`.\n\nTitle: %s\nIssue: %s' "$identifier" "$branch_name" "$CODEX_MODEL" "$title" "$issue_url")"
  log_issue_info "$identifier" "Moved to \`$LINEAR_IN_PROGRESS_STATE_NAME\` on branch \`$branch_name\` using model $CODEX_MODEL."
  checkout_issue_branch "$branch_name"

  log_issue_info "$identifier" "Starting Codex session."
  if run_codex_for_issue "$issue_json"; then
    log_issue_success "$identifier" "Codex session completed."
    if ! git_has_changes; then
      issue_add_comment "$issue_id" "Agent completed without producing a diff. Returning issue to \`$LINEAR_TODO_STATE_NAME\`."
      git -C "$ROOT_DIR" checkout "$GIT_BASE_BRANCH" >/dev/null 2>&1 || true
      issue_update_state "$issue_id" "$TODO_STATE_ID"
      log_issue_warn "$identifier" "Codex completed without producing a diff; returned to \`$LINEAR_TODO_STATE_NAME\`."
      return 1
    fi

    if ! commit_issue_changes "$issue_json"; then
      issue_add_comment "$issue_id" "Agent failed while committing changes for \`$identifier\`. The branch was left in place for inspection."
      log_issue_error "$identifier" "Failed while committing changes."
      return 1
    fi

    commit_sha="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
    issue_add_comment "$issue_id" "$(printf 'Agent committed `%s` on branch `%s` (commit `%s`). Preparing pull request.' "$identifier" "$branch_name" "$commit_sha")"
    log_issue_success "$identifier" "Committed changes on \`$branch_name\` (commit $commit_sha)."

    if ! pr_url="$(create_pull_request "$issue_json" "$branch_name")"; then
      issue_add_comment "$issue_id" "Agent implemented \`$identifier\` but failed to open a PR. The branch and commit were left in place for inspection."
      log_issue_error "$identifier" "Implemented changes but failed to open PR."
      return 1
    fi

    if ! pr_number="$(extract_pr_number_from_url "$pr_url")"; then
      issue_add_comment "$issue_id" "Agent opened PR $pr_url but could not determine its number. The branch and commit were left in place for inspection."
      log_issue_warn "$identifier" "Opened PR but could not parse PR number from URL."
      return 1
    fi
    summary="$(git_status_summary)"
    save_issue_state "$identifier" "$branch_name" "$pr_url" "$pr_number"
    issue_add_comment "$issue_id" "$(printf 'Agent opened PR %s from branch `%s` and moved the issue to `%s`.\n\nGit status:\n```text\n%s\n```' "$pr_url" "$branch_name" "$LINEAR_IN_REVIEW_STATE_NAME" "${summary:-clean}")"
    issue_update_state "$issue_id" "$IN_REVIEW_STATE_ID"
    git -C "$ROOT_DIR" checkout "$GIT_BASE_BRANCH" >/dev/null 2>&1 || true
    log_issue_success "$identifier" "Opened PR $pr_url and moved issue to \`$LINEAR_IN_REVIEW_STATE_NAME\`."
  else
    issue_add_comment "$issue_id" "Agent failed while implementing \`$identifier\`. Returning issue to \`$LINEAR_TODO_STATE_NAME\`."
    git -C "$ROOT_DIR" checkout "$GIT_BASE_BRANCH" >/dev/null 2>&1 || true
    issue_update_state "$issue_id" "$TODO_STATE_ID"
    log_issue_error "$identifier" "Codex session failed; returned to \`$LINEAR_TODO_STATE_NAME\`."
    return 1
  fi
}

run_once() {
  local review_issue
  local issue_json

  review_issue="$(pick_next_in_review_issue || true)"
  if [[ -n "$review_issue" ]]; then
    if reconcile_in_review_issue "$review_issue"; then
      clear_idle_notice
      return 0
    fi
  else
    clear_waiting_issue_state
  fi

  issue_json="$(pick_next_todo_issue || true)"
  if [[ -z "$issue_json" ]]; then
    remember_idle_notice "no-todo" "No \`$LINEAR_TODO_STATE_NAME\` or \`$LINEAR_BACKLOG_STATE_NAME\` issues found in project '$LINEAR_PROJECT_NAME'. Agent is idle."
    return 0
  fi

  clear_idle_notice
  process_issue "$issue_json"
}

run_forever() {
  local interval="${1:-30}"

  while true; do
    run_once || true
    sleep "$interval"
  done
}

print_context() {
  jq -n \
    --arg project_id "$PROJECT_ID" \
    --arg team_id "$TEAM_ID" \
    --arg backlog_state_id "$BACKLOG_STATE_ID" \
    --arg todo_state_id "$TODO_STATE_ID" \
    --arg in_progress_state_id "$IN_PROGRESS_STATE_ID" \
    --arg in_review_state_id "$IN_REVIEW_STATE_ID" \
    --arg done_state_id "$DONE_STATE_ID" \
    '{
      project_id: $project_id,
      team_id: $team_id,
      backlog_state_id: $backlog_state_id,
      todo_state_id: $todo_state_id,
      in_progress_state_id: $in_progress_state_id,
      in_review_state_id: $in_review_state_id,
      done_state_id: $done_state_id
    }'
}

usage() {
  cat <<'EOF'
Usage:
  ./scripts/agent.sh context
  ./scripts/agent.sh run-once
  ./scripts/agent.sh run-forever [seconds]
  ./scripts/agent.sh reconcile
EOF
}

main() {
  local command="${1:-}"

  ensure_prerequisites
  resolve_context
  AGENT_COMMAND="$command"

  case "$command" in
    context)
      print_context
      ;;
    run-once)
      run_once
      ;;
    run-forever)
      run_forever "${2:-30}"
      ;;
    reconcile)
      review_issue="$(pick_next_in_review_issue || true)"
      [[ -n "$review_issue" ]] || { log_info "No \`$LINEAR_IN_REVIEW_STATE_NAME\` issues found."; exit 0; }
      reconcile_in_review_issue "$review_issue"
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

AGENT_ORIGINAL_ARGS=("$@")
main "$@"

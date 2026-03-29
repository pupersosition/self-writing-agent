#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$ROOT_DIR/.linear-agent"
LOG_DIR="$STATE_DIR/logs"
ISSUE_STATE_DIR="$STATE_DIR/issues"
LIB_DIR="$ROOT_DIR/scripts/lib"

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


reconcile_in_review_issue() {
  local issue_json="$1"
  local identifier
  local issue_id
  local saved_state
  local pr_url
  local pr_number
  local pr_data
  local merged_at

  identifier="$(jq -r '.identifier' <<<"$issue_json")"
  issue_id="$(jq -r '.id' <<<"$issue_json")"
  saved_state="$(load_issue_state "$identifier" || true)"
  [[ -n "$saved_state" ]] || return 1

  require_gh_auth
  pr_url="$(jq -r '.pr_url' <<<"$saved_state")"
  pr_number="$(jq -r '.pr_number' <<<"$saved_state")"
  pr_data="$(gh pr view "$pr_url" --repo "$GITHUB_REPO" --json state,mergedAt,url,reviewDecision,isDraft)"
  merged_at="$(jq -r '.mergedAt // empty' <<<"$pr_data")"

  if [[ -n "$merged_at" ]] && pr_has_approval "$pr_number"; then
    issue_add_comment "$issue_id" "PR approved and merged: $(jq -r '.url' <<<"$pr_data"). Marking issue \`Done\`."
    issue_update_state "$issue_id" "$DONE_STATE_ID"
    return 0
  fi

  echo "waiting:$identifier"
  return 1
}

process_issue() {
  local issue_json="$1"
  local issue_id
  local identifier
  local title
  local summary
  local branch_name
  local pr_url
  local pr_number

  issue_id="$(jq -r '.id' <<<"$issue_json")"
  identifier="$(jq -r '.identifier' <<<"$issue_json")"
  title="$(jq -r '.title' <<<"$issue_json")"
  branch_name="$(issue_branch_name "$issue_json")"

  if ! preflight_for_issue; then
    issue_add_comment "$issue_id" "Agent could not start \`$identifier\` because the local git or GitHub CLI prerequisites are not satisfied."
    return 1
  fi

  clear_issue_context "$identifier"
  issue_update_state "$issue_id" "$IN_PROGRESS_STATE_ID"
  issue_add_comment "$issue_id" "Agent started implementing \`$identifier\`: $title"
  checkout_issue_branch "$branch_name"

  if run_codex_for_issue "$issue_json"; then
    if ! git_has_changes; then
      issue_add_comment "$issue_id" "Agent completed without producing a diff. Returning issue to \`$LINEAR_TODO_STATE_NAME\`."
      git -C "$ROOT_DIR" checkout "$GIT_BASE_BRANCH" >/dev/null 2>&1 || true
      issue_update_state "$issue_id" "$TODO_STATE_ID"
      return 1
    fi

    if ! commit_issue_changes "$issue_json"; then
      issue_add_comment "$issue_id" "Agent failed while committing changes for \`$identifier\`. The branch was left in place for inspection."
      return 1
    fi

    if ! pr_url="$(create_pull_request "$issue_json" "$branch_name")"; then
      issue_add_comment "$issue_id" "Agent implemented \`$identifier\` but failed to open a PR. The branch and commit were left in place for inspection."
      return 1
    fi

    if ! pr_number="$(extract_pr_number_from_url "$pr_url")"; then
      issue_add_comment "$issue_id" "Agent opened PR $pr_url but could not determine its number. The branch and commit were left in place for inspection."
      return 1
    fi
    summary="$(git_status_summary)"
    save_issue_state "$identifier" "$branch_name" "$pr_url" "$pr_number"
    issue_add_comment "$issue_id" "$(printf 'Agent opened PR %s and moved the issue to `%s`.\n\nGit status:\n```text\n%s\n```' "$pr_url" "$LINEAR_IN_REVIEW_STATE_NAME" "${summary:-clean}")"
    issue_update_state "$issue_id" "$IN_REVIEW_STATE_ID"
    git -C "$ROOT_DIR" checkout "$GIT_BASE_BRANCH" >/dev/null 2>&1 || true
    echo "opened-pr:$identifier"
  else
    issue_add_comment "$issue_id" "Agent failed while implementing \`$identifier\`. Returning issue to \`$LINEAR_TODO_STATE_NAME\`."
    git -C "$ROOT_DIR" checkout "$GIT_BASE_BRANCH" >/dev/null 2>&1 || true
    issue_update_state "$issue_id" "$TODO_STATE_ID"
    echo "failed:$identifier" >&2
    return 1
  fi
}

run_once() {
  local review_issue
  local issue_json

  review_issue="$(pick_next_in_review_issue || true)"
  if [[ -n "$review_issue" ]] && reconcile_in_review_issue "$review_issue"; then
    return 0
  fi

  issue_json="$(pick_next_todo_issue || true)"
  if [[ -z "$issue_json" ]]; then
    echo "No Todo issues found in project '$LINEAR_PROJECT_NAME'."
    return 0
  fi

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
      [[ -n "$review_issue" ]] || { echo "No In Review issues found."; exit 0; }
      reconcile_in_review_issue "$review_issue"
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"

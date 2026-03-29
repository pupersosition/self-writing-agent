#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$ROOT_DIR/.linear-agent"
LOG_DIR="$STATE_DIR/logs"
ISSUE_STATE_DIR="$STATE_DIR/issues"

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
LINEAR_CLI_BIN="${LINEAR_CLI_BIN:-$ROOT_DIR/node_modules/.bin/lin}"
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

json_escape() {
  jq -Rn --arg value "$1" '$value'
}

graphql() {
  local query="$1"
  local variables="${2:-{}}"
  local payload
  local response

  payload="$(jq -cn --arg q "$query" --argjson v "$variables" '{query: $q, variables: $v}')"
  response="$(
    curl -fsS "$LINEAR_API_URL" \
      -H 'Content-Type: application/json' \
      -H "Authorization: $LINEAR_API_KEY" \
      --data "$payload"
  )"

  if jq -e '.errors and (.errors | length > 0)' >/dev/null <<<"$response"; then
    jq '.errors' <<<"$response" >&2
    return 1
  fi

  printf '%s\n' "$response"
}

resolve_project_id() {
  graphql 'query { projects(first: 50) { nodes { id name } } }' |
    jq -r --arg name "$LINEAR_PROJECT_NAME" '.data.projects.nodes[] | select(.name == $name) | .id' |
    head -n 1
}

resolve_team_id() {
  graphql 'query { teams(first: 50) { nodes { id key name } } }' |
    jq -r --arg team_name "$LINEAR_TEAM_NAME" --arg team_key "$LINEAR_TEAM_KEY" '
      .data.teams.nodes[]
      | select(.name == $team_name or .key == $team_key)
      | .id
    ' |
    head -n 1
}

resolve_state_id() {
  local state_name="$1"

  graphql "query { team(id: \"$TEAM_ID\") { states { nodes { id name } } } }" |
    jq -r --arg state_name "$state_name" '.data.team.states.nodes[] | select(.name == $state_name) | .id' |
    head -n 1
}

resolve_context() {
  PROJECT_ID="$(resolve_project_id)"
  TEAM_ID="$(resolve_team_id)"

  [[ -n "$PROJECT_ID" ]] || {
    echo "Unable to resolve Linear project: $LINEAR_PROJECT_NAME" >&2
    exit 1
  }
  [[ -n "$TEAM_ID" ]] || {
    echo "Unable to resolve Linear team: $LINEAR_TEAM_NAME / $LINEAR_TEAM_KEY" >&2
    exit 1
  }

  BACKLOG_STATE_ID="$(resolve_state_id "$LINEAR_BACKLOG_STATE_NAME")"
  TODO_STATE_ID="$(resolve_state_id "$LINEAR_TODO_STATE_NAME")"
  IN_PROGRESS_STATE_ID="$(resolve_state_id "$LINEAR_IN_PROGRESS_STATE_NAME")"
  IN_REVIEW_STATE_ID="$(resolve_state_id "$LINEAR_IN_REVIEW_STATE_NAME")"
  DONE_STATE_ID="$(resolve_state_id "$LINEAR_DONE_STATE_NAME")"

  [[ -n "$BACKLOG_STATE_ID" && -n "$TODO_STATE_ID" && -n "$IN_PROGRESS_STATE_ID" && -n "$IN_REVIEW_STATE_ID" && -n "$DONE_STATE_ID" ]] || {
    echo "Unable to resolve one or more required workflow states" >&2
    exit 1
  }
}

fetch_project_issues() {
  graphql "query { project(id: \"$PROJECT_ID\") { issues(first: 50) { nodes { id identifier title description url branchName state { id name type } createdAt updatedAt } } } }"
}

fetch_issue_by_id() {
  local issue_id="$1"

  graphql "query { issue(id: \"$issue_id\") { id identifier title url state { id name type } } }"
}

pick_next_issue_by_state() {
  local state_name="$1"

  fetch_project_issues |
    jq -c --arg state_name "$state_name" '
      .data.project.issues.nodes
      | map(select(.state.name == $state_name))
      | sort_by(.createdAt)
      | .[0] // empty
    '
}

pick_next_todo_issue() {
  pick_next_issue_by_state "$LINEAR_TODO_STATE_NAME"
}

pick_next_in_review_issue() {
  pick_next_issue_by_state "$LINEAR_IN_REVIEW_STATE_NAME"
}

issue_update_state() {
  local issue_id="$1"
  local state_id="$2"

  graphql 'mutation($id: String!, $input: IssueUpdateInput!) { issueUpdate(id: $id, input: $input) { success } }' \
    "$(jq -cn --arg id "$issue_id" --arg stateId "$state_id" '{id: $id, input: {stateId: $stateId}}')" >/dev/null
}

issue_add_comment() {
  local issue_id="$1"
  local body="$2"

  graphql 'mutation($input: CommentCreateInput!) { commentCreate(input: $input) { success } }' \
    "$(jq -cn --arg issueId "$issue_id" --arg body "$body" '{input: {issueId: $issueId, body: $body}}')" >/dev/null
}

create_issue_api() {
  local title="$1"
  local description="$2"
  local state_id="$3"

  graphql 'mutation($input: IssueCreateInput!) { issueCreate(input: $input) { success issue { id identifier title } } }' \
    "$(jq -cn \
      --arg teamId "$TEAM_ID" \
      --arg projectId "$PROJECT_ID" \
      --arg stateId "$state_id" \
      --arg title "$title" \
      --arg description "$description" \
      '{input: {teamId: $teamId, projectId: $projectId, stateId: $stateId, title: $title, description: $description}}'
    )"
}

find_issue_by_title() {
  local title="$1"

  graphql "query { team(id: \"$TEAM_ID\") { issues(first: 50) { nodes { id identifier title createdAt } } } }" |
    jq -c --arg title "$title" '
      .data.team.issues.nodes
      | map(select(.title == $title))
      | sort_by(.createdAt)
      | last // empty
    '
}

issue_state_file() {
  local identifier="$1"
  printf '%s/%s.json\n' "$ISSUE_STATE_DIR" "$identifier"
}

save_issue_state() {
  local identifier="$1"
  local branch="$2"
  local pr_url="$3"
  local pr_number="$4"

  jq -n \
    --arg identifier "$identifier" \
    --arg branch "$branch" \
    --arg pr_url "$pr_url" \
    --arg pr_number "$pr_number" \
    '{
      identifier: $identifier,
      branch: $branch,
      pr_url: $pr_url,
      pr_number: $pr_number
    }' >"$(issue_state_file "$identifier")"
}

load_issue_state() {
  local identifier="$1"
  local state_file

  state_file="$(issue_state_file "$identifier")"
  [[ -f "$state_file" ]] || return 1
  cat "$state_file"
}

create_backlog_issue() {
  local title="$1"
  local description="$2"

  create_issue_api "$title" "$description" "$BACKLOG_STATE_ID" |
    jq -r '.data.issueCreate.issue.identifier'
}

create_issue_with_lin() {
  local title="$1"
  local description="$2"

  [[ -x "$LINEAR_CLI_BIN" ]] || {
    echo "Linear CLI not found at $LINEAR_CLI_BIN" >&2
    exit 1
  }

  "$LINEAR_CLI_BIN" new --team "$LINEAR_TEAM_KEY" --title "$title" --description "$description" >/dev/null
  find_issue_by_title "$title"
}

codex_issue_prompt() {
  local issue_json="$1"
  local identifier
  local title
  local description

  identifier="$(jq -r '.identifier' <<<"$issue_json")"
  title="$(jq -r '.title' <<<"$issue_json")"
  description="$(jq -r '.description // ""' <<<"$issue_json")"

  cat <<EOF
You are implementing Linear issue $identifier for the repository at $ROOT_DIR.

Issue title:
$title

Issue description:
$description

Instructions:
- Make the smallest correct change in this repository.
- Add or update tests if the issue needs them.
- Do not commit or push.
- At the end, print a short summary and the verification you ran.
EOF
}

run_codex_for_issue() {
  local issue_json="$1"
  local identifier
  local log_file

  identifier="$(jq -r '.identifier' <<<"$issue_json")"
  log_file="$LOG_DIR/${identifier}.log"

  codex exec \
    -C "$ROOT_DIR" \
    -s workspace-write \
    -a never \
    --model "$CODEX_MODEL" \
    "$(codex_issue_prompt "$issue_json")" | tee "$log_file"
}

git_status_summary() {
  git -C "$ROOT_DIR" status --short || true
}

ensure_remote() {
  if ! git -C "$ROOT_DIR" remote get-url "$GIT_REMOTE_NAME" >/dev/null 2>&1; then
    git -C "$ROOT_DIR" remote add "$GIT_REMOTE_NAME" "https://github.com/$GITHUB_REPO.git"
  fi
}

require_gh_auth() {
  gh auth status >/dev/null 2>&1 || {
    echo "gh is installed but not authenticated. Run: gh auth login -h github.com" >&2
    return 1
  }
}

require_base_commit() {
  git -C "$ROOT_DIR" rev-parse --verify HEAD >/dev/null 2>&1 || {
    echo "The repository needs at least one base commit before the agent can create PR branches." >&2
    return 1
  }
}

require_clean_worktree() {
  [[ -z "$(git -C "$ROOT_DIR" status --short)" ]] || {
    echo "The worktree must be clean before processing a new issue." >&2
    return 1
  }
}

require_git_identity() {
  local user_name
  local user_email

  user_name="$(git -C "$ROOT_DIR" config user.name || true)"
  user_email="$(git -C "$ROOT_DIR" config user.email || true)"

  [[ -n "$user_name" && -n "$user_email" ]] || {
    echo "git user.name and user.email must be configured before the agent can commit." >&2
    return 1
  }
}

preflight_for_issue() {
  ensure_remote
  require_gh_auth
  require_base_commit
  require_clean_worktree
  require_git_identity
}

slugify() {
  tr '[:upper:]' '[:lower:]' <<<"$1" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

issue_branch_name() {
  local issue_json="$1"
  local identifier
  local title

  identifier="$(jq -r '.identifier' <<<"$issue_json" | tr '[:upper:]' '[:lower:]')"
  title="$(jq -r '.title' <<<"$issue_json")"
  printf '%s/%s\n' "$identifier" "$(slugify "$title")"
}

checkout_issue_branch() {
  local branch_name="$1"

  git -C "$ROOT_DIR" checkout "$GIT_BASE_BRANCH" >/dev/null 2>&1 || true
  git -C "$ROOT_DIR" pull --ff-only "$GIT_REMOTE_NAME" "$GIT_BASE_BRANCH" >/dev/null 2>&1 || true
  git -C "$ROOT_DIR" checkout -B "$branch_name" "$GIT_BASE_BRANCH" >/dev/null
}

git_has_changes() {
  [[ -n "$(git -C "$ROOT_DIR" status --short)" ]]
}

commit_issue_changes() {
  local issue_json="$1"
  local identifier
  local title

  identifier="$(jq -r '.identifier' <<<"$issue_json")"
  title="$(jq -r '.title' <<<"$issue_json")"

  git -C "$ROOT_DIR" add -A
  git -C "$ROOT_DIR" commit -m "Implement $identifier: $title" >/dev/null
}

create_pull_request() {
  local issue_json="$1"
  local branch_name="$2"
  local identifier
  local title
  local body

  identifier="$(jq -r '.identifier' <<<"$issue_json")"
  title="$(jq -r '.title' <<<"$issue_json")"
  body="$(printf 'Implements %s.\n\nLinear issue: %s' "$identifier" "$(jq -r '.url' <<<"$issue_json")")"

  git -C "$ROOT_DIR" push -u "$GIT_REMOTE_NAME" "$branch_name" >/dev/null
  gh pr create \
    --repo "$GITHUB_REPO" \
    --base "$GIT_BASE_BRANCH" \
    --head "$branch_name" \
    --title "Implement $identifier: $title" \
    --body "$body"
}

pr_has_approval() {
  local pr_number="$1"
  local approval_count

  approval_count="$(
    gh api "repos/$GITHUB_REPO/pulls/$pr_number/reviews" \
      --jq 'map(select(.state == "APPROVED")) | length'
  )"

  [[ "${approval_count:-0}" -gt 0 ]]
}

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

    pr_number="$(gh pr view "$pr_url" --repo "$GITHUB_REPO" --json number -q '.number')"
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
  local interval="${1:-60}"

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
  ./scripts/agent.sh create-backlog-issue "title" "description"
  ./scripts/agent.sh create-test-issue "title" "description"
  ./scripts/agent.sh show-issue ISSUE_ID
  ./scripts/agent.sh move-issue-to-todo ISSUE_ID
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
      run_forever "${2:-60}"
      ;;
    create-backlog-issue)
      [[ $# -eq 3 ]] || { usage >&2; exit 1; }
      create_backlog_issue "$2" "$3"
      ;;
    create-test-issue)
      [[ $# -eq 3 ]] || { usage >&2; exit 1; }
      create_issue_with_lin "$2" "$3"
      ;;
    show-issue)
      [[ $# -eq 2 ]] || { usage >&2; exit 1; }
      fetch_issue_by_id "$2"
      ;;
    move-issue-to-todo)
      [[ $# -eq 2 ]] || { usage >&2; exit 1; }
      issue_update_state "$2" "$TODO_STATE_ID"
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

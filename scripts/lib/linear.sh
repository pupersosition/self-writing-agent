: "${LINEAR_GRAPHQL_MAX_ATTEMPTS:=3}"
: "${LINEAR_GRAPHQL_BACKOFF_BASE_SECONDS:=1}"

linear__log_warn() {
  if declare -F log_warn >/dev/null 2>&1; then
    log_warn "$@"
  else
    printf '[WARN] %s\n' "$*" >&2
  fi
}

linear__log_error() {
  if declare -F log_error >/dev/null 2>&1; then
    log_error "$@"
  else
    printf '[ERROR] %s\n' "$*" >&2
  fi
}

graphql() {
  local query="$1"
  local variables
  local payload
  local response
  local attempt=1
  local max_attempts
  local backoff_base
  local tmp_response
  local http_status
  local cause=""
  local should_retry=0
  local success=0
  local sleep_seconds
  local attempts_left
  local curl_exit

  max_attempts="$LINEAR_GRAPHQL_MAX_ATTEMPTS"
  if ! [[ "$max_attempts" =~ ^[0-9]+$ ]] || (( max_attempts < 1 )); then
    max_attempts=3
  fi

  backoff_base="$LINEAR_GRAPHQL_BACKOFF_BASE_SECONDS"
  if ! [[ "$backoff_base" =~ ^[0-9]+$ ]]; then
    backoff_base=1
  fi

  if [[ $# -ge 2 ]]; then
    variables="$2"
  else
    variables='{}'
  fi

  payload="$(printf '%s' "$variables" | jq -c --arg q "$query" '{query: $q, variables: .}')"
  tmp_response="$(mktemp)"

  while (( attempt <= max_attempts )); do
    should_retry=0
    cause=""

    if http_status="$(
      curl -sS "$LINEAR_API_URL" \
        -H 'Content-Type: application/json' \
        -H "Authorization: $LINEAR_API_KEY" \
        --data "$payload" \
        -o "$tmp_response" \
        -w '%{http_code}'
    )"; then
      response="$(<"$tmp_response")"
      if (( http_status == 429 || (http_status >= 500 && http_status < 600) )); then
        cause="HTTP $http_status"
        should_retry=1
      elif (( http_status >= 400 )); then
        rm -f "$tmp_response"
        linear__log_error "Linear GraphQL request failed with HTTP $http_status"
        printf '%s\n' "$response" >&2
        return 1
      fi
    else
      curl_exit=$?
      cause="curl exit $curl_exit"
      should_retry=1
    fi

    if (( should_retry )); then
      if (( attempt >= max_attempts )); then
        break
      fi
      attempts_left=$(( max_attempts - attempt ))
      sleep_seconds=$(( backoff_base * (2 ** (attempt - 1)) ))
      linear__log_warn "Linear GraphQL attempt ${attempt} failed (${cause}); retrying in ${sleep_seconds}s (${attempts_left} attempts left)."
      sleep "$sleep_seconds"
      attempt=$(( attempt + 1 ))
      continue
    fi

    success=1
    break
  done

  rm -f "$tmp_response"

  if (( success == 0 )); then
    linear__log_error "Linear GraphQL request failed after ${max_attempts} attempts (${cause:-unknown error})."
    return 1
  fi

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
  graphql "query { project(id: \"$PROJECT_ID\") { issues(first: 50) { nodes { id identifier title description url branchName state { id name type } createdAt updatedAt attachments(first: 25) { nodes { id title subtitle url metadata } } } } } }"
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
  fetch_project_issues |
    jq -c --arg todo_state "$LINEAR_TODO_STATE_NAME" --arg backlog_state "$LINEAR_BACKLOG_STATE_NAME" '
      .data.project.issues.nodes
      | map(select(.state.name == $todo_state or .state.name == $backlog_state))
      | sort_by(if .state.name == $todo_state then 0 else 1 end, .createdAt)
      | .[0] // empty
    '
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

issue_create() {
  local title="$1"
  local description="$2"
  local state_id="${3:-$BACKLOG_STATE_ID}"
  local payload
  local response

  payload="$(
    jq -cn \
      --arg teamId "$TEAM_ID" \
      --arg projectId "$PROJECT_ID" \
      --arg stateId "$state_id" \
      --arg title "$title" \
      --arg description "$description" \
      '{input: {teamId: $teamId, projectId: $projectId, title: $title, description: $description, stateId: $stateId}}'
  )"

  response="$(
    graphql 'mutation($input: IssueCreateInput!) { issueCreate(input: $input) { issue { id identifier title url } } }' "$payload"
  )"

  jq '.data.issueCreate.issue' <<<"$response"
}

issue_state_file() {
  local identifier="$1"
  printf '%s/%s.json\n' "$ISSUE_STATE_DIR" "$identifier"
}

clear_issue_context() {
  local identifier="$1"
  local state_file log_file

  state_file="$(issue_state_file "$identifier")"
  log_file="$LOG_DIR/${identifier}.log"

  rm -f "$state_file" "$log_file"
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

issue_current_state_name() {
  local issue_id="$1"

  graphql "query { issue(id: \"$issue_id\") { state { name } } }" \
    | jq -r '.data.issue.state.name // empty'
}

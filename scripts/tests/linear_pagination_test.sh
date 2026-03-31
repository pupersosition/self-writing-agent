#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$ROOT_DIR/scripts/lib"

# shellcheck source=../lib/linear.sh
source "$LIB_DIR/linear.sh"

# Override the Linear GraphQL call so tests can feed deterministic fixtures.
graphql() {
  local _query="$1"
  local variables="${2:-{}}"
  if [[ "$variables" == *'"after":null'* ]]; then
    printf '%s\n' "$LINEAR_TEST_PAGE_ONE"
  else
    printf '%s\n' "$LINEAR_TEST_PAGE_TWO"
  fi
}

FIXTURE_PAGE_ONE_WITH_BACKLOG="$(cat <<'JSON'
{
  "data": {
    "project": {
      "issues": {
        "pageInfo": {
          "hasNextPage": true,
          "endCursor": "cursor-page-1"
        },
        "nodes": [
          {
            "id": "issue-backlog",
            "identifier": "SEL-99",
            "title": "Backlog issue on first page",
            "description": "",
            "url": "https://linear.app/SEL-99",
            "branchName": "",
            "state": { "id": "state-backlog", "name": "Backlog", "type": "backlog" },
            "createdAt": "2024-01-01T00:00:00.000Z",
            "updatedAt": "2024-01-01T00:00:00.000Z",
            "attachments": { "nodes": [] }
          }
        ]
      }
    }
  }
}
JSON
)"

FIXTURE_PAGE_ONE_NO_CANDIDATE="$(cat <<'JSON'
{
  "data": {
    "project": {
      "issues": {
        "pageInfo": {
          "hasNextPage": true,
          "endCursor": "cursor-page-1"
        },
        "nodes": [
          {
            "id": "issue-in-progress",
            "identifier": "SEL-21",
            "title": "In Progress work",
            "description": "",
            "url": "https://linear.app/SEL-21",
            "branchName": "",
            "state": { "id": "state-in-progress", "name": "In Progress", "type": "inProgress" },
            "createdAt": "2024-01-01T00:00:00.000Z",
            "updatedAt": "2024-01-01T00:00:00.000Z",
            "attachments": { "nodes": [] }
          }
        ]
      }
    }
  }
}
JSON
)"

FIXTURE_PAGE_TWO_DEFAULT="$(cat <<'JSON'
{
  "data": {
    "project": {
      "issues": {
        "pageInfo": {
          "hasNextPage": false,
          "endCursor": null
        },
        "nodes": [
          {
            "id": "issue-todo",
            "identifier": "SEL-52",
            "title": "Todo item beyond first page",
            "description": "",
            "url": "https://linear.app/SEL-52",
            "branchName": "",
            "state": { "id": "state-todo", "name": "Todo", "type": "started" },
            "createdAt": "2024-01-02T00:00:00.000Z",
            "updatedAt": "2024-01-02T00:00:00.000Z",
            "attachments": { "nodes": [] }
          },
          {
            "id": "issue-review",
            "identifier": "SEL-53",
            "title": "Review item beyond first page",
            "description": "",
            "url": "https://linear.app/SEL-53",
            "branchName": "",
            "state": { "id": "state-review", "name": "In Review", "type": "triage" },
            "createdAt": "2024-01-03T00:00:00.000Z",
            "updatedAt": "2024-01-03T00:00:00.000Z",
            "attachments": { "nodes": [] }
          }
        ]
      }
    }
  }
}
JSON
)"

reset_linear_env() {
  PROJECT_ID="test-project"
  LINEAR_BACKLOG_STATE_NAME="Backlog"
  LINEAR_TODO_STATE_NAME="Todo"
  LINEAR_IN_REVIEW_STATE_NAME="In Review"
  LINEAR_PROJECT_ISSUE_PAGE_SIZE=50
  LINEAR_PROJECT_ISSUE_SCAN_CAP=500
}

use_default_fixture() {
  LINEAR_TEST_PAGE_ONE="$FIXTURE_PAGE_ONE_WITH_BACKLOG"
  LINEAR_TEST_PAGE_TWO="$FIXTURE_PAGE_TWO_DEFAULT"
}

run_tests=0
run_failures=0

run_test() {
  local name="$1"
  shift
  if "$@"; then
    printf 'PASS %s\n' "$name"
  else
    printf 'FAIL %s\n' "$name"
    run_failures=$((run_failures + 1))
  fi
  run_tests=$((run_tests + 1))
}

test_pick_next_todo_issue_reads_beyond_first_page() {
  reset_linear_env
  use_default_fixture
  local issue_json
  issue_json="$(pick_next_todo_issue)"
  [[ -n "$issue_json" ]] || return 1
  [[ "$(jq -r '.identifier' <<<"$issue_json")" == "SEL-52" ]]
}

test_pick_next_in_review_issue_reads_beyond_first_page() {
  reset_linear_env
  use_default_fixture
  local issue_json
  issue_json="$(pick_next_in_review_issue)"
  [[ -n "$issue_json" ]] || return 1
  [[ "$(jq -r '.identifier' <<<"$issue_json")" == "SEL-53" ]]
}

test_pick_next_todo_issue_warns_when_truncated_without_match() {
  reset_linear_env
  LINEAR_PROJECT_ISSUE_SCAN_CAP=1
  LINEAR_TEST_PAGE_ONE="$FIXTURE_PAGE_ONE_NO_CANDIDATE"
  LINEAR_TEST_PAGE_TWO="$FIXTURE_PAGE_TWO_DEFAULT"

  local warn_output
  warn_output="$({ pick_next_todo_issue >/dev/null; } 2>&1)"
  [[ "$warn_output" == *"Linear backlog scan truncated"* ]]
}

run_test "pick_next_todo_issue_reads_beyond_first_page" test_pick_next_todo_issue_reads_beyond_first_page
run_test "pick_next_in_review_issue_reads_beyond_first_page" test_pick_next_in_review_issue_reads_beyond_first_page
run_test "pick_next_todo_issue_warns_when_truncated_without_match" test_pick_next_todo_issue_warns_when_truncated_without_match

printf '\nRan %d test(s); %d failed.\n' "$run_tests" "$run_failures"

if (( run_failures > 0 )); then
  exit 1
fi

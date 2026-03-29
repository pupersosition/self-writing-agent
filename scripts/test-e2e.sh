#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENT_BIN="$ROOT_DIR/scripts/agent.sh"
TEST_FILE="$ROOT_DIR/AGENT_E2E_TEST.md"
STAMP="$(date +%s)"
TITLE="E2E test issue $STAMP"
DESCRIPTION=$'Create a file named AGENT_E2E_TEST.md in the repository root with the exact contents:\n\nhello from linear e2e\n'

rm -f "$TEST_FILE"

issue_json="$("$AGENT_BIN" create-test-issue "$TITLE" "$DESCRIPTION")"
issue_id="$(jq -r '.id' <<<"$issue_json")"
identifier="$(jq -r '.identifier' <<<"$issue_json")"

"$AGENT_BIN" move-issue-to-todo "$issue_id"
"$AGENT_BIN" run-once

[[ -f "$TEST_FILE" ]] || {
  echo "Expected $TEST_FILE to exist after processing $identifier" >&2
  exit 1
}

expected='hello from linear e2e'
actual="$(cat "$TEST_FILE")"
[[ "$actual" == "$expected" ]] || {
  echo "Unexpected file contents in $TEST_FILE" >&2
  printf 'expected: %s\nactual: %s\n' "$expected" "$actual" >&2
  exit 1
}

issue_state_file="$ROOT_DIR/.linear-agent/issues/${identifier}.json"
[[ -f "$issue_state_file" ]] || {
  echo "Expected PR metadata file $issue_state_file to exist" >&2
  exit 1
}

pr_url="$(jq -r '.pr_url' "$issue_state_file")"
[[ -n "$pr_url" && "$pr_url" != "null" ]] || {
  echo "Expected a pull request URL for $identifier" >&2
  exit 1
}

printf 'E2E reached PR stage for %s: %s\n' "$identifier" "$pr_url"

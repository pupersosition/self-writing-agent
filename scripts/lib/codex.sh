codex_issue_prompt() {
  local issue_json="$1"
  local identifier
  local title
  local description

  identifier="$(jq -r '.identifier' <<<"$issue_json")"
  title="$(jq -r '.title' <<<"$issue_json")"
  description="$(jq -r '.description // ""' <<<"$issue_json")"

  cat <<EOF_PROMPT
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
EOF_PROMPT
}

run_codex_for_issue() {
  local issue_json="$1"
  local identifier
  local log_file

  identifier="$(jq -r '.identifier' <<<"$issue_json")"
  log_file="$LOG_DIR/${identifier}.log"

  codex -a never exec \
    -C "$ROOT_DIR" \
    -s workspace-write \
    --model "$CODEX_MODEL" \
    "$(codex_issue_prompt "$issue_json")" | tee "$log_file"
}

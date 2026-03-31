codex_issue_prompt() {
  local issue_json="$1"
  local identifier
  local title
  local description
  local attachments_listing

  identifier="$(jq -r '.identifier' <<<"$issue_json")"
  title="$(jq -r '.title' <<<"$issue_json")"
  description="$(jq -r '.description // ""' <<<"$issue_json")"
  attachments_listing="$(jq -r '
    (.attachments.nodes // [])
    | map(
        "- " +
        (if (.title // "") != "" then .title else "Attachment" end) +
        (if (.subtitle // "") != "" then " — " + .subtitle else "" end) +
        (if (.url // "") != "" then "\n  URL: " + .url else "" end)
      )
    | join("\n")
  ' <<<"$issue_json")"

  cat <<EOF_PROMPT
You are implementing Linear issue $identifier for the repository at $ROOT_DIR.

Issue title:
$title

Issue description:
$description

EOF_PROMPT

  if [[ -n "$attachments_listing" ]]; then
    cat <<EOF_PROMPT
Issue attachments:
$attachments_listing

EOF_PROMPT
  fi

  cat <<'EOF_PROMPT'

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

codex_self_review_prompt() {
  local tasks_file="$1"
  local existing_issues="$2"
  local max_tasks="${3:-3}"

  cat <<EOF_PROMPT
You are auditing the repository at $ROOT_DIR to identify small, high-leverage improvements.

Existing Linear issues:
${existing_issues:-(none)}

Instructions:
- Inspect the current scripts and docs for gaps in automation, resilience, or observability.
- Propose between 1 and $max_tasks concrete follow-up tasks that fit within this repository.
- Each task needs a short title (<= 80 chars), a multi-sentence description, and 1-3 acceptance criteria.
- Write the tasks as JSON to \"$tasks_file\" in the form:
  [
    {
      \"title\": \"...\",
      \"description\": \"...\",
      \"acceptanceCriteria\": [\"...\"]
    }
  ]
- Keep the descriptions actionable and reference the relevant files.
- Do not modify any project files besides \"$tasks_file\".
- After writing the file, print a short summary of the findings.
EOF_PROMPT
}

run_codex_self_review() {
  local tasks_file="$1"
  local existing_issues="$2"
  local max_tasks="${3:-3}"
  local log_file="$LOG_DIR/self-review.log"

  codex -a never exec \
    -C "$ROOT_DIR" \
    -s workspace-write \
    --model "$CODEX_MODEL" \
    "$(codex_self_review_prompt "$tasks_file" "$existing_issues" "$max_tasks")" | tee "$log_file"
}

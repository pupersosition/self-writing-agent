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

pull_latest_agent_source() {
  local previous_sha
  local current_sha
  local pull_output

  previous_sha="$(git -C "$ROOT_DIR" rev-parse "$GIT_BASE_BRANCH" 2>/dev/null || true)"

  git -C "$ROOT_DIR" checkout "$GIT_BASE_BRANCH" >/dev/null 2>&1 || true

  if ! pull_output="$(git -C "$ROOT_DIR" pull --ff-only "$GIT_REMOTE_NAME" "$GIT_BASE_BRANCH" 2>&1)"; then
    echo "Failed to pull latest agent source: $pull_output" >&2
    return 2
  fi

  current_sha="$(git -C "$ROOT_DIR" rev-parse "$GIT_BASE_BRANCH" 2>/dev/null || true)"

  if [[ "$previous_sha" == "$current_sha" ]]; then
    return 1
  fi

  return 0
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

issue_log_file() {
  local identifier="$1"
  printf '%s/%s.log\n' "$LOG_DIR" "$identifier"
}

issue_summary_from_log() {
  local identifier="$1"
  local log_file

  log_file="$(issue_log_file "$identifier")"
  [[ -f "$log_file" ]] || return 0

  perl -0ne '
    my $text = $_;
    if ($text =~ /(.*?)(\n\s*(?:\*\*)?verification(?:\*\*)?\b.*)/is) {
      $text = $1;
    }
    $text =~ s/\A\s+//s;
    $text =~ s/\s+\z//s;
    print $text;
  ' "$log_file"
}

issue_root_cause_from_description() {
  local issue_json="$1"
  local description
  local extracted

  description="$(jq -r '.description // ""' <<<"$issue_json")"
  [[ -n "$description" ]] || return 0

  extracted="$(
    DESCRIPTION="$description" perl - <<'PERL'
use strict;
use warnings;

my $text = $ENV{DESCRIPTION} // '';
my @lines = split /\n/, $text;
my $collect = 0;
my @buffer;

for my $line (@lines) {
  my $trimmed = $line;
  $trimmed =~ s/^\s+|\s+$//g;
  my $norm = lc $trimmed;

  if (!$collect) {
    if ($norm =~ /^(?:#+\s*)?root cause\b/ || $norm =~ /^\*\*root cause\*\*/ || $norm =~ /^root cause\b/) {
      $collect = 1;
      $line =~ s/^(?:#+\s*)?root cause\b[:\s\-]*//i;
      $line =~ s/^\*\*root cause\*\*[:\s\-]*//i;
      $line =~ s/^root cause\b[:\s\-]*//i;
      push @buffer, $line if $line =~ /\S/;
    }
    next;
  }

  last if $trimmed =~ /^#{1,6}\s+\S/;
  last if $trimmed =~ /^\*\*[A-Za-z0-9 ,:-]+\*\*\s*$/;

  push @buffer, $line;
}

while (@buffer && $buffer[-1] =~ /^\s*$/) {
  pop @buffer;
}

if (@buffer) {
  print join("\n", @buffer);
}
PERL
  )"

  [[ -n "$extracted" ]] || return 0
  printf '%s\n' "$extracted"
}

build_pull_request_body() {
  local issue_url="$1"
  local summary_text="$2"
  local root_cause_text="$3"
  local body

  body="## Summary"$'\n'

  if [[ -n "$summary_text" ]]; then
    body+="$summary_text"$'\n\n'
  else
    body+="Not provided."$'\n\n'
  fi

  if [[ -n "$root_cause_text" ]]; then
    body+="## Root Cause"$'\n'"$root_cause_text"$'\n\n'
  fi

  body+="## Linear Issue"$'\n'"$issue_url"
  printf '%s\n' "$body"
}

create_pull_request() {
  local issue_json="$1"
  local branch_name="$2"
  local identifier
  local title
  local issue_url
  local summary_text
  local root_cause_text
  local body

  identifier="$(jq -r '.identifier' <<<"$issue_json")"
  title="$(jq -r '.title' <<<"$issue_json")"
  issue_url="$(jq -r '.url' <<<"$issue_json")"
  summary_text="$(issue_summary_from_log "$identifier")"
  root_cause_text="$(issue_root_cause_from_description "$issue_json")"
  body="$(build_pull_request_body "$issue_url" "$summary_text" "$root_cause_text")"

  git -C "$ROOT_DIR" push -u "$GIT_REMOTE_NAME" "$branch_name" >/dev/null
  gh pr create \
    --repo "$GITHUB_REPO" \
    --base "$GIT_BASE_BRANCH" \
    --head "$branch_name" \
    --title "Implement $identifier: $title" \
    --body "$body"
}

extract_pr_number_from_url() {
  local pr_url="$1"

  if [[ "$pr_url" =~ /pull/([0-9]+)([^0-9].*)?$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
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

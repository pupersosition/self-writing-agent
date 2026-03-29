# Self Writing Agent

Prototype bash agent that watches the Linear project `Self writing agent`, picks the next ready issue, implements it by delegating to the local `codex` CLI, opens a PR in `pupersosition/self-writing-agent`, and only marks the Linear issue `Done` after the PR is approved and merged.

## Requirements

- `bash`
- `curl`
- `jq`
- `codex`
- `git`
- `gh`
- `LINEAR_API_KEY`
- configured `git user.name` and `git user.email`

## Configuration

Export the required environment before launching the loop so the agent can reach the right Linear project and GitHub repo:

```bash
export LINEAR_API_KEY="lin_api_your_token" # required
export LINEAR_PROJECT_NAME="Self writing agent" # override to point at another Linear project
export LINEAR_TEAM_KEY="SEL"                 # keep in sync with the target Linear team
export GITHUB_REPO="pupersosition/self-writing-agent" # set to your fork when testing locally
```

Then authenticate once with GitHub (`gh auth login`) and ensure `git config user.name` / `user.email` are set so `scripts/agent.sh` can create branches and commits without interactivity.

The loop uses:

- Linear GraphQL for project filtering, comments, and state transitions
- `gh` for PR creation and merge detection
- `codex exec` for the actual repo implementation step

## Main Loop

Run a single iteration:

```bash
./scripts/agent.sh run-once
```

Run continuously:

```bash
./scripts/agent.sh run-forever 30
```

## Issue Execution Model

The current prototype turns each `Todo` issue into a `codex exec` prompt. A good issue description should clearly describe the intended repo change and expected verification.

State flow:

- `Todo`: picked first when available
- `Backlog`: picked if there is no `Todo` issue
- `In Progress`: agent is implementing on a branch
- `In Review`: PR is open and the agent is waiting for review and merge
- `Done`: agent only sets this after a later polling pass confirms the PR merged through `gh`

The loop expects you to:

1. Create an issue in the `Self writing agent` Linear project.
2. Let the loop pick it up and open a PR.
3. Approve and merge the PR.
4. Leave the loop running so it can observe the merged PR and move the issue to `Done`.

Example:

```text
Add a short setup section to README.md describing how to start the agent loop.
```

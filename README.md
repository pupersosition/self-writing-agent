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

# Self Writing Agent

Prototype bash agent that watches the Linear project `Self writing agent`, creates backlog issues, and implements `Todo` issues by delegating the repo work to the local `codex` CLI.

## Requirements

- `bash`
- `curl`
- `jq`
- `codex`
- `git`
- `gh`
- `LINEAR_API_KEY`
- configured `git user.name` and `git user.email`

The repo also vendors the Linear CLI as `./node_modules/.bin/lin`. The current CLI only supports `new` and `checkout`, so the agent uses:

- `lin new` for issue creation when possible
- Linear GraphQL for project filtering, issue selection, comments, and state transitions
- `gh` for pull request creation and merge detection

## Main Loop

Run a single iteration:

```bash
./scripts/agent.sh run-once
```

Create a backlog issue:

```bash
./scripts/agent.sh create-backlog-issue "Title" "Description"
```

Create a real test issue and drive it through implementation and PR creation:

```bash
./scripts/test-e2e.sh
```

## Issue Execution Model

The current prototype turns each `Todo` issue into a `codex exec` prompt. A good issue description should clearly describe the intended repo change and expected verification.

State flow:

- `Backlog`: issue exists but is not executable yet
- `Todo`: eligible for the agent to pick up
- `In Progress`: agent is implementing on a branch
- `In Review`: PR is open and the agent is waiting for review and merge
- `Done`: agent only sets this after a later polling pass confirms the PR merged through `gh`

The agent will not mark an issue `Done` immediately after changing files.

Example:

```text
Create a file named AGENT_E2E_TEST.md with the exact contents:

hello from linear e2e
```

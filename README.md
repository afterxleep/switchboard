# Switchboard

**Autonomous dev loop for iOS projects.** Switchboard monitors your Linear backlog, assigns issues to a Codex coding agent, tracks the work from first commit to merged PR, and ensures nothing goes stale.

Built on top of the [OpenAI Codex CLI](https://github.com/openai/codex) app-server protocol, inspired by [Symphony](https://github.com/openai/symphony).

---

## What it does

1. **Picks up Linear issues** — Polls your Linear team for issues in the `Todo` state
2. **Spins up a Codex agent** — Runs `codex app-server` per issue in an isolated git worktree
3. **Persists the session** — One Codex thread per issue, kept alive for the full lifecycle
4. **Monitors the PR** — Tracks CI, review comments, conflicts, and approvals automatically
5. **Reacts to feedback** — Routes PR comments and CI failures back to the same Codex thread (full context preserved)
6. **Manages Linear state** — Moves issues between `In Progress` / `In Review` / `Done` automatically
7. **Zero stale work** — A PR is never forgotten; it is tracked until actively merged

### State transitions

```
Linear: Todo
    ↓  (daemon picks up issue)
Linear: In Progress  ←──────────────────────────────────┐
    ↓  (Codex codes, opens PR)                           │
    ↓  (ALL conditions met — see gate below)             │
Linear: In Review  ──── (new comment / CI red / conflict)┘
    ↓  (approved + all conditions still met → auto-merge)
Linear: Done  ✓
```

---

## The state machine — the most important part

> **The flow is the product. Without a predictable, consistent flow, the tool is useless.**

### In Progress

An issue is **In Progress** whenever any of the following is true — even one:

- The agent is actively running (coding, fixing CI, addressing comments)
- CI is failing
- There are unresolved review threads on the PR
- There are merge conflicts
- The PR is not yet open

**Default state for any active work. When in doubt: In Progress.**

### In Review

An issue moves to **In Review** only when ALL of the following are simultaneously true:

| Condition | Must be |
|-----------|---------|
| CI | ✅ 100% green, all checks passed |
| Review threads | ✅ Zero unresolved |
| Merge conflicts | ✅ None |
| Agent | ✅ Not currently running |

This is a gate, not a step. All four conditions are checked atomically before any transition. One false → stays In Progress.

### In Review is not a terminal state

**The daemon continues actively monitoring every PR in In Review on every tick.**

If any condition changes — a new comment appears, CI reruns and goes red, a conflict emerges — the daemon immediately:
1. Moves the Linear issue back to **In Progress**
2. Resumes the Codex session (same thread, full context)
3. Addresses the new work

A PR is never forgotten. It stays in active tracking from the moment the issue is picked up until the merge is confirmed in GitHub.

### Done

An issue is **Done** only when both are true:
- PR is **actively merged** in GitHub
- Linear issue is closed

"Approved" is not done. "Ready to merge" is not done. Merged is done.

---

## Requirements

- macOS 14+
- [OpenAI Codex CLI](https://github.com/openai/codex) `v0.114.0+` — installed at `/opt/homebrew/bin/codex` (or configure `CODEX_COMMAND`)
- Linear workspace with API access
- GitHub personal access token with `repo` scope
- A git repository for your project (Switchboard creates worktrees inside it)

---

## Installation

### Build from source

```bash
git clone https://github.com/afterxleep/switchboard
cd switchboard
swift build -c release
cp .build/release/flowdeck-daemon /usr/local/bin/switchboard
```

### Configure

Create a `.env` file or export the following environment variables:

```bash
# Required
LINEAR_API_KEY=lin_api_xxxxxxxxxxxxxxxxxxxx
GITHUB_TOKEN=ghp_xxxxxxxxxxxxxxxxxxxx

# Agent identity — the daemon ONLY monitors issues and PRs belonging to this agent
LINEAR_ASSIGNEE_ID=<linear-user-uuid>          # Only Linear issues assigned to this user
GITHUB_ASSIGNEE=kaimercercli                   # Only PRs opened by this GitHub handle

# Linear configuration
LINEAR_TEAM_SLUG=DB                             # Your team's identifier prefix (e.g. "DB" for DB-123)
LINEAR_IN_PROGRESS_STATE_ID=<uuid>              # "In Progress" state UUID
LINEAR_IN_REVIEW_STATE_ID=<uuid>               # "In Review" state UUID
LINEAR_DONE_STATE_ID=<uuid>                    # "Done" state UUID

# GitHub configuration
GITHUB_REPO=owner/repo                         # e.g. "afterxleep/flowdeck"

# Repository path (Switchboard creates git worktrees here)
REPO_PATH=~/Developer/your-repo

# Optional tuning
POLL_INTERVAL_SECONDS=60
INFLIGHT_TIMEOUT_SECONDS=1800                  # Re-queue stuck agents after 30 min
STALL_TIMEOUT_SECONDS=1800                     # Kill a Codex session with no output after this long
MAX_AGENT_RETRIES=3                            # Park an issue after this many consecutive failures
MAX_CONCURRENT_AGENTS=6                        # Max parallel Codex sessions
CI_FAILURE_THRESHOLD=2                         # Trigger CI fix after this many failures
CODEX_COMMAND=/opt/homebrew/bin/codex          # Path to codex CLI
WORKSPACE_ROOT=~/.switchboard/workspaces       # Where worktrees are created
```

### Get your Linear state IDs

```bash
curl -s -X POST https://api.linear.app/graphql \
  -H "Authorization: YOUR_LINEAR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"query": "{ workflowStates { nodes { id name } } }"}' \
  | jq '.data.workflowStates.nodes[] | select(.name | test("In Progress|In Review|Done"))'
```

### Set up workflow templates

Switchboard uses markdown templates to instruct the Codex agent. Create `~/.switchboard/` with these files:

**`~/.switchboard/WORKFLOW.md`** — Used when starting a new issue:
```markdown
You are a coding agent working on {{ISSUE_IDENTIFIER}}: {{ISSUE_TITLE}}.

{{ISSUE_DESCRIPTION}}

## Rules
- Write clean, well-tested Swift code
- Follow existing patterns in the codebase
- Run the test suite before committing
- Set git identity before committing:
  git config user.email "agent@yourdomain.com"
  git config user.name "Your Agent"
- Commit with message: "{{ISSUE_IDENTIFIER}}: <description>"
- Push the branch and open a PR when done
```

**`~/.switchboard/WORKFLOW_REVIEW.md`** — Used when addressing PR review comments:
```markdown
You are working on {{ISSUE_IDENTIFIER}}: {{ISSUE_TITLE}}.
PR #{{PR_NUMBER}} has a review comment that needs to be addressed.

{{COMMENT_AUTHOR}} commented on {{COMMENT_PATH}}:
{{COMMENT_BODY}}

Address the feedback, run tests, commit and push.
```

**`~/.switchboard/WORKFLOW_CI.md`** — Used when CI is failing:
```markdown
You are working on {{ISSUE_IDENTIFIER}}: {{ISSUE_TITLE}}.
PR #{{PR_NUMBER}} has failing CI checks: {{FAILED_CHECKS}}

Fix the failing tests/build. Run tests locally, commit and push.
```

**`~/.switchboard/WORKFLOW_CONFLICT.md`** — Used when merge conflicts appear:
```markdown
You are working on {{ISSUE_IDENTIFIER}}: {{ISSUE_TITLE}}.
PR #{{PR_NUMBER}} has merge conflicts with main.

Rebase onto main, resolve conflicts, run tests, force-push.
```

---

## Running

### One-shot
```bash
switchboard
```

### Check status
```bash
switchboard status
```
Shows active and parked issues at a glance.

### Reset a parked issue
```bash
switchboard reset DB-165
switchboard reset DB-165 DB-196 DB-197   # multiple at once
```
Resets the retry count so the daemon picks it up on the next tick. Use this after fixing the underlying problem (e.g. topping up API credit, fixing a broken prompt).


### As a background service (launchd on macOS)

Create `~/Library/LaunchAgents/com.switchboard.daemon.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.switchboard.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/switchboard</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>LINEAR_API_KEY</key>
        <string>lin_api_xxxxxxxxxxxxxxxxxxxx</string>
        <key>GITHUB_TOKEN</key>
        <string>ghp_xxxxxxxxxxxxxxxxxxxx</string>
        <key>GITHUB_REPO</key>
        <string>owner/repo</string>
        <key>REPO_PATH</key>
        <string>/Users/you/Developer/your-repo</string>
        <key>LINEAR_TEAM_SLUG</key>
        <string>DB</string>
        <key>LINEAR_IN_PROGRESS_STATE_ID</key>
        <string>your-state-uuid</string>
        <key>LINEAR_IN_REVIEW_STATE_ID</key>
        <string>your-state-uuid</string>
        <key>LINEAR_DONE_STATE_ID</key>
        <string>your-state-uuid</string>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/switchboard.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/switchboard-error.log</string>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.switchboard.daemon.plist
```

---

## How it works

### Issue lifecycle

```
Todo issue detected
    → git worktree created at $WORKSPACE_ROOT/<issue-id>/
    → codex app-server launched (JSON-RPC over stdio)
    → Linear issue moved to "In Progress"
    → Codex turn started with WORKFLOW.md prompt
    → Agent codes, commits, pushes, opens PR
    → turn/completed signal received
    → threadId + threadPath stored in state

PR detected on matching branch
    → prNumber linked to issue state
    → phase: waitingOnCI

All CI checks pass, no open review threads
    → Linear issue moved to "In Review"
    → phase: waitingOnReview

Review comment or unresolved thread appears
    → Linear issue moved back to "In Progress"
    → codex app-server launched, SAME thread resumed
    → Agent has full conversation history — knows exactly what it built
    → Addresses feedback, pushes
    → phase: addressingFeedback → waitingOnReview (when clean)

PR merged
    → Linear issue moved to "Done"
    → Workspace cleaned up
    → State entry marked done
```

### State persistence

State is stored in SQLite at `~/.switchboard/state.db`. Each issue entry tracks:
- Linear issue ID and identifier
- Codex thread ID and session path (for resumption)
- PR number
- Current lifecycle phase
- Retry count and consecutive CI failure count

### Concurrency

Each Linear issue runs in its own Swift `Task`. The daemon loop polls on a configurable interval and manages all active tasks concurrently without blocking.

---

## Architecture

```
switchboard/
├── Sources/
│   ├── Daemon/
│   │   └── main.swift              Entry point, wires everything together
│   └── DaemonCore/
│       ├── DaemonLoop.swift        Main orchestration loop
│       ├── DaemonConfig.swift      Configuration from environment
│       ├── DaemonEvent.swift       Event types (newIssue, ciFailure, etc.)
│       ├── StateEntry.swift        Per-issue lifecycle state
│       ├── StateStore.swift        State persistence (JSON)
│       ├── AgentPhase.swift        Lifecycle phase enum
│       ├── AgentRunner.swift       Orchestrates workspace + Codex session
│       ├── AgentRunning.swift      Protocol
│       ├── CodexAppServerClient.swift  JSON-RPC client for codex app-server
│       ├── CodexAppServerRunning.swift Protocol
│       ├── WorkspaceManager.swift  Git worktree lifecycle
│       ├── WorkspaceManaging.swift Protocol
│       ├── LinearPoller.swift      Polls Linear for new issues
│       ├── LinearPolling.swift     Protocol
│       ├── LinearStateManager.swift    Mutates Linear issue states
│       ├── GitHubPoller.swift      Polls GitHub for PR events
│       ├── GitHubPolling.swift     Protocol
│       └── EventDispatcher.swift   Fallback: fires openclaw events
└── Tests/
    └── DaemonCoreTests/            Full test suite
```

---

## State database

State is stored in SQLite at `~/.switchboard/state.db`. Use `switchboard status` for a human-readable view. For raw inspection:

```bash
sqlite3 ~/.switchboard/state.db \
  "SELECT id, status, agent_phase, retry_count, consecutive_ci_failures FROM state_entries;"
```

Key columns:

| Column | Description |
|--------|-------------|
| `id` | Entry key, e.g. `linear:DB-196` or `gh:pr:122` |
| `status` | `pending` / `inFlight` / `done` |
| `agent_phase` | `coding` / `waitingOnCI` / `addressingFeedback` / `waitingOnReview` / `ciBlocked` / `done` |
| `retry_count` | Consecutive agent failures. Parked when ≥ `MAX_AGENT_RETRIES` (default 3) |
| `consecutive_ci_failures` | Parked in `ciBlocked` when ≥ `MAX_CONSECUTIVE_CI_FAILURES` (default 10) |

---

## Security

- **API keys** are passed via environment variables, never stored in code or state
- Switchboard only writes to the configured `WORKSPACE_ROOT` directory and `~/.switchboard/`
- The Codex agent runs with `danger-full-access` sandbox (required for git operations) — only run on trusted codebases
- Review Codex agent output in PR diffs before merging

---

## Contributing

This project is in active development. Issues and PRs welcome.

The daemon is designed to be generic — not tied to any specific language or toolchain. The workflow templates are the only project-specific layer.

---

## License

MIT

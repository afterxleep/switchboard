# Switchboard Flow

> This document defines the canonical state machine. The daemon implementation must match this exactly. If there is ever a conflict between this document and the code, the code is wrong.

---

## The fundamental rule

**Work is in progress until it is merged. Nothing else counts.**

The Linear state exists to communicate truthfully what is happening. A Linear issue in "In Review" must mean exactly one thing: the work is complete, the PR is clean, and it is waiting for a human decision to merge. It must never mean "the agent finished its last turn and we're not sure what happens next."

---

## State definitions

### `In Progress`

The issue is actively being worked on. Something still needs to happen before this is ready for a human to look at.

**The issue is In Progress when any of these is true:**
- The agent is running a turn (coding, addressing comments, fixing CI, resolving conflicts)
- CI is failing on the PR
- There are unresolved review threads on the PR
- There are merge conflicts on the PR
- The PR has not been opened yet

This is the default state for anything that isn't definitively clean.

### `In Review`

The work is complete. The PR is clean. A human can now review and approve it.

**The issue moves to In Review only when ALL of the following are simultaneously true:**

1. **CI is 100% green** — every check run has passed, none are pending or failing
2. **Zero unresolved review threads** — every inline code comment thread is resolved
3. **Zero merge conflicts** — the branch merges cleanly into main
4. **No active agent turn** — the agent is not currently running for this issue

These four conditions are checked atomically in a single gate function. If even one is false, the issue stays In Progress. There is no partial "mostly ready" state.

### `Done`

The issue is complete. Both conditions must be true:

1. **The PR is merged in GitHub** (not just approved — actively merged)
2. **The Linear issue is closed**

"Approved" is not done. "Ready to merge" is not done. "Agent finished its turn" is not done. Merged is done.

---

## Full lifecycle

```
┌─────────────────────────────────────────────────────┐
│  Linear: Todo                                       │
│  GitHub: no PR                                      │
└──────────────┬──────────────────────────────────────┘
               │  Daemon picks up issue
               ▼
┌─────────────────────────────────────────────────────┐
│  Linear: In Progress                                │
│  Agent: coding (new codex thread created)           │
│  GitHub: no PR yet                                  │
└──────────────┬──────────────────────────────────────┘
               │  Agent opens PR
               ▼
┌─────────────────────────────────────────────────────┐
│  Linear: In Progress                                │
│  Agent: idle (turn completed)                       │
│  GitHub: PR open, CI running                        │
│  prNumber attached to state entry                   │
└──────────────┬──────────────────────────────────────┘
               │  ALL gate conditions met
               │  (CI green + no threads + no conflicts + agent idle)
               ▼
┌─────────────────────────────────────────────────────┐
│  Linear: In Review  ◄────────────────────────────┐  │
│  Agent: idle                                     │  │
│  GitHub: PR clean, awaiting approval             │  │
│                                                  │  │
│  Daemon monitors every tick:                     │  │
│  • New thread appears ───────────────────────────┼──┤
│  • CI goes red ──────────────────────────────────┼──┤
│  • Conflict detected ────────────────────────────┼──┘
└──────────────┬──────────────────────────────────────┘
               │  Approved + all gate conditions still met
               ▼
         Auto-merge triggered
               │
               ▼
┌─────────────────────────────────────────────────────┐
│  Linear: Done                                       │
│  GitHub: PR merged                                  │
│  Workspace: cleaned up                              │
└─────────────────────────────────────────────────────┘
```

---

## What happens when In Review goes back to In Progress

When the daemon detects any blocking condition on a PR currently in `waitingOnReview`:

1. Immediately moves Linear issue to **In Progress** (before any other action)
2. Collects all unresolved threads, CI failures, and conflicts
3. Passes them all to the existing Codex thread in a single turn (agent sees full context)
4. Waits for `turn/completed`
5. After turn completes: re-checks all gate conditions
6. If all pass → moves to **In Review** again
7. If not → stays **In Progress**, waits for the next event

The agent is always resumed on the **same Codex thread** — it has full history of everything it has built on this issue.

---

## Comment resolution

When the agent addresses PR review comments:

1. Daemon passes all unresolved threads to the agent in a single turn
2. Agent addresses them all in one cohesive commit and pushes
3. On `turn/completed`: daemon resolves every submitted thread via GitHub GraphQL API
4. Daemon re-polls for any remaining threads before transitioning state

A thread is only marked resolved in GitHub after the agent's turn completes and a push is confirmed. Never before.

---

## Auto-merge conditions

The daemon merges automatically when all of these are true:

| Condition | Check |
|-----------|-------|
| Approved | At least one approving review |
| CI | All checks green |
| Threads | Zero unresolved |
| Conflicts | Branch merges cleanly |

Merge method: squash. Commit title: `<ISSUE_ID>: <PR title>`.

The daemon attempts auto-merge:
- When an `approved` event arrives
- When `ciPassed` arrives and the PR was already approved
- When an agent turn completes and returns to `waitingOnReview`

---

## Reviewer assignment

When a PR is opened, the daemon immediately requests a review from the configured `GITHUB_REVIEWER`. This happens once, automatically, as part of the `prOpened` handling.

---

## Error handling

- **Agent turn fails** → retry (up to `MAX_AGENT_RETRIES`). Issue stays In Progress.
- **Merge fails** → log, stay in `waitingOnReview`, retry on next tick.
- **Review request fails** → log and continue. Non-fatal.
- **Linear API fails** → log and continue. State is eventually consistent.
- **After max retries** → issue stays In Progress, daemon notifies via configured channel.

---

## What never happens

- An issue moves to In Review while the agent is running
- An issue moves to In Review when CI is failing
- An issue moves to In Review when unresolved threads exist
- An issue moves to In Review when conflicts exist
- A PR in In Review is ignored if new events arrive
- A merged PR leaves the Linear issue open
- Done is declared before the PR is actively merged

# Daemon Refactor Task

Do a full architecture and logic review of this Swift daemon. Goal: simpler, more reliable, easier to maintain.

## Current Problems (production observed)

1. **Self-heal oscillation**: `reconcile()` moves CI-capped issues from `addressingFeedback` → `waitingOnCI` every tick, then CI fails → back to `addressingFeedback`. Infinite loop. The CI ceiling check exists in `startAgentIfIdle` but `reconcile()` ignores it.

2. **Concurrency overscheduling (4/3)**: Logs show "concurrency cap reached (4/3)" — 4 agents running when max is 3. The count check is not atomic with agent start.

3. **Complex self-heal logic**: `reconcile()` has 5 self-heal loops that interact with event routing, creating oscillation that is hard to reason about.

4. **Stale entry snapshots**: `startAgentIfIdle(event:entry:)` receives a snapshot that may be stale by the time it runs.

5. **No stable CI-blocked state**: Issues with broken CI have no permanent "parked" state — they keep oscillating through phases.

## Files to review
- Sources/DaemonCore/DaemonLoop.swift
- Sources/DaemonCore/StateEntry.swift
- Sources/DaemonCore/DaemonConfig.swift
- Sources/DaemonCore/AgentPhase.swift
- Sources/DaemonCore/StateStore.swift

## What to do

### 1. Read all files above thoroughly

### 2. Write ARCHITECTURE_REVIEW.md at repo root
Cover: what each component does, where complexity comes from, failure modes, simplest correct design.

### 3. Rewrite DaemonLoop.swift with these principles

- **CI ceiling is a phase, not a check**: add `ciBlocked` to `AgentPhase`. When `consecutiveCIFailures >= maxConsecutiveCIFailures`, set phase to `ciBlocked` and stay there. Only `ciPassed` event resets it (resets counter + moves to `waitingOnCI`). No other code touches CI-blocked entries.

- **reconcile() handles only timeout recovery**: remove all self-heal loops that move phases forward. Those should only fire from events (ciPassed, prOpened, etc). reconcile() should only: (a) re-queue timed-out inFlight entries, and (b) check waitingOnReview entries for new unresolved threads.

- **Atomic concurrency reservation**: in `startAgentIfIdle`, use `agentLock` to atomically check-and-increment the count before starting. Never check count outside the lock.

- **startAgentIfIdle always loads fresh state**: ignore the passed-in entry for all checks. Load from stateStore directly.

- **Phase transitions are event-driven only**: ciFailure → ciBlocked (if ceiling hit) or addressingFeedback. ciPassed → waitingOnCI or waitingOnReview. prOpened → waitingOnCI. prMerged → merged. reviewComment/unresolvedThread → addressingFeedback. No phase changes in reconcile except timeout re-queue.

### 4. After rewriting
- Run `swift test` — all tests must pass (fix tests if interface changed)
- Run `swift build -c release`
- Run `cp .build/release/daemon ~/bin/flowdeck-daemon`
- Run `launchctl kickstart -k gui/$(id -u)/com.flowdeck.daemon`
- Wait 90 seconds, check logs, verify no oscillation
- Run `git add -A && git commit -m "refactor: simplify DaemonLoop — ciBlocked phase, atomic concurrency, event-driven transitions"`

When completely finished run:
openclaw system event --text "Daemon refactor complete. Binary rebuilt and restarted." --mode now

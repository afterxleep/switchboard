# Architecture Review — FlowDeck Daemon

## Component Summary

### DaemonLoop
The central orchestrator. Each `tick()`:
1. Processes completed agent results (`processCompletedAgents`)
2. Runs reconciliation (`reconcile`)
3. Polls Linear and GitHub for new events
4. Normalizes and routes events to handlers
5. Retries timed-out dispatches, checks completions, cleans up state

### AgentPhase
State machine for issue lifecycle: `coding → waitingOnCI → waitingOnReview → addressingFeedback → merged → done`. Before this refactor, there was no stable "parked" state for CI-blocked issues.

### StateEntry
Persistent record per tracked issue/PR. Holds phase, PR number, retry counts, CI failure counts, pending thread node IDs. Stored as a JSON dictionary keyed by entry ID.

### StateStore
File-backed persistence layer. Every mutation loads the full state file, modifies in memory, writes back atomically. No in-process caching — every call is a full round-trip to disk.

### DaemonConfig
Immutable configuration: API keys, thresholds, file paths. Key tunables: `maxConcurrentAgents`, `maxConsecutiveCIFailures`, `ciFailureThreshold`, `maxAgentRetries`.

## Where Complexity Came From

### 1. Self-heal loops in reconcile()
Five separate loops that scan all entries and move phases forward:
- coding + PR attached → waitingOnCI
- addressingFeedback + no threads/conflicts → waitingOnCI
- waitingOnCI + CI passing → waitingOnReview or addressingFeedback
- waitingOnReview + unresolved threads → addressingFeedback
- inFlight + timed out → pending (re-queue)

These were added incrementally to handle missed transitions, but they overlap with event-driven transitions in `route()`, creating two competing sources of truth for phase changes.

### 2. No CI-blocked state
When CI failures hit the ceiling, `startAgentIfIdle` refuses to start agents, but `reconcile()` doesn't know about the ceiling. It sees `addressingFeedback` with no threads and advances to `waitingOnCI`. Next tick, CI fails again → back to `addressingFeedback`. Infinite oscillation.

### 3. Non-atomic concurrency check
`startAgentIfIdle` reads `runningAgents.count` under lock, then starts the agent in a separate call outside the lock. Between those two points, another event on the same tick can also pass the count check, leading to 4/3 overscheduling.

### 4. Stale entry snapshots
`startAgentIfIdle(event:entry:)` receives an `entry` parameter that was loaded earlier in the tick. By the time it runs, the entry may have been modified by earlier event routing in the same tick. The partial fix (reloading inside the function) was added but the parameter still exists as an unreliable input.

## Failure Modes (Pre-Refactor)

| Symptom | Root Cause |
|---|---|
| Self-heal oscillation | reconcile advances phases that events will immediately revert |
| 4/3 concurrency | Count check not atomic with agent start |
| CI-blocked issues never park | No stable `ciBlocked` phase; ceiling is a runtime check only |
| Stale phase decisions | Entry snapshot passed as parameter, not loaded fresh |

## Simplest Correct Design (Implemented)

1. **`ciBlocked` is a phase**: `AgentPhase` gains a `ciBlocked` case. When `consecutiveCIFailures >= maxConsecutiveCIFailures`, phase is set to `ciBlocked`. Only a `ciPassed` event can exit this phase. No other code touches ciBlocked entries.

2. **reconcile() does only two things**: (a) re-queue timed-out inFlight entries, (b) check waitingOnReview entries for new unresolved threads. All other phase transitions are event-driven only.

3. **Atomic concurrency reservation**: `startAgentIfIdle` checks count AND inserts into `runningAgents` in a single `agentLock.withLock` block. The agent Task is stored as a placeholder before starting.

4. **Fresh state always**: `startAgentIfIdle` loads the entry from stateStore directly, ignoring the passed-in snapshot.

5. **Phase transitions are event-driven**: Each event handler in `route()` owns its transitions. reconcile() never moves entries forward through the pipeline.

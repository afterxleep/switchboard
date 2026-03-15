# Kai Task: Remove forward phase transitions from reconcile()

## The bug

`reconcile()` in `DaemonLoop.swift` is still doing forward phase transitions — log evidence:
```
self-healed linear:DB-177: no threads/conflicts, advancing to waitingOnCI
```

`reconcile()` must ONLY handle timeout recovery (reset stalled/hung entries back to idle). It must NEVER advance an entry forward to a new phase. That is the event system's job.

## TDD — tests first

Add to `Tests/DaemonCoreTests/` a new test file `ReconcileTests.swift`:

1. **reconcile does not advance phases forward** — given an entry in `addressingFeedback` phase with no conflicts/threads, call `reconcile()`, confirm phase is unchanged
2. **reconcile resets timed-out inFlight entries** — given an entry stuck `inFlight` with `startedAt` >2h ago, call `reconcile()`, confirm it resets to idle/coding
3. **reconcile does not touch ciBlocked entries** — entry in `ciBlocked`, call `reconcile()`, phase unchanged
4. **reconcile does not touch waitingOnCI entries** — entry in `waitingOnCI`, call `reconcile()`, phase unchanged

Run `swift test` — tests should be RED before the fix.

## Fix

In `DaemonLoop.swift`, find `reconcile()` and remove any logic that:
- Checks PR thread state, conflicts, or CI status to advance phase
- Calls `updatePhase` with any forward-moving phase (e.g. `waitingOnCI`, `coding`, `addressingFeedback`)
- Has any `self-healed` or `advancing to` log messages

`reconcile()` after the fix should ONLY:
- Find entries where `status == .inFlight` and `startedAt` is older than the timeout threshold
- Reset those timed-out entries back to a safe state (e.g. reset `agentPhase` to `.coding`, clear `sessionId`/`agentPid`)
- Log something like "reconcile: reset timed-out entry X"

Nothing else. No PR checks. No thread checks. No phase advancement.

## After fix

1. `swift test` — all tests must pass including the new ones
2. `swift build -c release 2>&1`
3. `cp .build/release/daemon ~/bin/flowdeck-daemon`
4. `launchctl kickstart -k gui/$(id -u)/com.flowdeck.daemon`
5. Watch `~/.flowdeck-daemon/daemon-stderr.log` for 5 minutes — confirm zero `self-healed` lines
6. Write `/tmp/kai-reconcile-result.txt` with: tests pass/fail, build pass/fail, whether `self-healed` lines still appear, last 20 log lines

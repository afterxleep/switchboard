# Kai Task: Find and remove ALL self-heal logic from the daemon

## The problem

The running daemon (PID 59931, started 18:53 UTC) is still logging:
```
self-healed linear:DB-186: no threads/conflicts, advancing to waitingOnCI
```

These appear after agent stall events. The string "heal", "no threads", "advancing to" do NOT appear anywhere in `Sources/` via grep or binary search. Yet the running process emits it.

## Your job

1. Find every place in the codebase that could produce this behavior — phase transitions from `addressingFeedback` or any phase to `waitingOnCI` outside of explicit events.

2. Specifically look for:
   - Any function that checks `hasUnresolvedThreads` or `hasConflicts` and advances phase
   - Any `updatePhase(id:phase:.waitingOnCI)` call that isn't triggered by a `.prOpened`, `.ciPassed`, or `.approved` event
   - Any `reconcile`-like function that isn't just the one in `DaemonLoop.swift`
   - Any timer, background task, or `completionWatcher` callback that moves phases forward

3. Look at ALL source files — not just DaemonLoop.swift. Check:
   - `AgentRunner.swift`
   - `CompletionWatcher.swift` (if it exists)
   - `EventDispatcher.swift`
   - Any other .swift files in Sources/

4. Write tests FIRST that catch this behavior:
   - Given an entry in `addressingFeedback` with no open threads and no conflicts — call the daemon's full tick — confirm the phase does NOT advance to `waitingOnCI` without an explicit event

5. Once found: remove the forward-transition logic. Keep ONLY event-driven phase changes.

6. Run `swift test` — all tests must pass.

7. `swift package clean && swift build -c release 2>&1`

8. `cp .build/release/daemon ~/bin/flowdeck-daemon`

9. `launchctl kickstart -k gui/$(id -u)/com.flowdeck.daemon`

10. Watch logs for 10 minutes: confirm ZERO `self-healed` lines.

11. Write `/tmp/kai-selfheal-final.txt`:
    - Where you found the logic (file + line)
    - What it was doing
    - What you removed/changed
    - Test results
    - Whether daemon is clean after 10 min
    - Last 20 log lines

## Rules
- TDD: write the test that catches it FIRST, confirm it's red, then fix, then green
- Do NOT modify test assertions to pass — fix the code
- Do NOT post to Linear or GitHub

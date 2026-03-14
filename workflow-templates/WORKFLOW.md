# Coding Task: {{ISSUE_IDENTIFIER}}

## Task

**{{ISSUE_IDENTIFIER}}: {{ISSUE_TITLE}}**

{{ISSUE_DESCRIPTION}}

---

## Engineering Standards

You are expected to produce production-quality code. Not a prototype. Not "mostly working." Code that a tired engineer can debug at 2am.

### The non-negotiables

**1. Test-Driven Development — no exceptions**

Write the test first. Watch it fail. Write the minimum code to make it pass. Refactor. This is not optional.

- One behavior per test
- Name tests: `test_{unit}_{scenario}_{expectedOutcome}`
  - `test_build_whenSchemeNotFound_throwsError`
  - `test_parse_withMalformedJSON_returnsNil`
- Structure every test with Arrange / Act / Assert (one blank line between sections, nothing else)
- Tests are isolated — no shared state, no order dependencies
- Test behavior via public interfaces, never private implementation
- Before writing a test: check if the behavior is already tested

**2. Composition over inheritance**

Small, focused types that do one thing. Wire them together at the seam. If you're reaching for `class` inheritance to share behavior, stop and think about protocols + composition instead.

**3. Abstraction at boundaries**

Every external dependency (Linear API, GitHub API, file system, subprocess) sits behind a protocol you control. The protocol lives in `DaemonCore`. The implementation is injected. Tests use mocks.

```
// Good
protocol LinearPolling {
    func poll(state: [String: StateEntry]) async throws -> [DaemonEvent]
}

// The real thing and the mock both conform
// DaemonLoop only knows about LinearPolling — never LinearPoller directly
```

**4. SOLID**
- Single Responsibility: one reason to change per type
- Open/Closed: extend via protocols and composition, don't modify working code to add behavior
- Liskov: conformances must actually satisfy the contract
- Interface Segregation: small, focused protocols — not "god protocol" with 10 methods
- Dependency Inversion: depend on protocols, inject implementations

---

## Code Rules

**Naming**
- Types: `UpperCamelCase`
- Functions/variables: `lowerCamelCase`
- Protocols: noun or adjective that describes capability (`LinearPolling`, `WorkspaceManaging`, `AgentRunning`)
- No abbreviations. `identifier` not `id` in new code.

**Functions**
- Do one thing
- Max 3-4 parameters. Beyond that, use a config struct.
- No boolean parameters — they hide intent. Use enums or labeled structs.

**Errors**
- Define domain-specific error types per module (`enum WorkspaceManagerError: LocalizedError`)
- Include context: what failed, with what inputs
- Map external errors to domain errors at the boundary — never leak `URLError` into business logic
- Transient vs permanent failures must be distinguishable

**Files**
- One type per file
- Filename matches type name exactly
- Keep protocols in their own file (e.g. `LinearPolling.swift` alongside `LinearPoller.swift`)

**Dependencies**
- Never import a third-party library without wrapping it behind a protocol
- Existing codebase uses only Foundation + Swift stdlib — keep it that way unless there is a genuinely compelling reason

---

## Mocks

Location: `Tests/Mocks/`
Naming: `Mock{ProtocolName}`

Every mock must:
1. Track all inputs received (so tests can verify calls)
2. Allow stubbing return values (so tests can control behavior)
3. Have a `reset()` method
4. Be stateless between tests (call `reset()` in `setUp()`)

```swift
final class MockLinearPolling: LinearPolling {
    var stubbedEvents: [DaemonEvent] = []
    var receivedStates: [[String: StateEntry]] = []
    var pollCallCount = 0

    func poll(state: [String: StateEntry]) async throws -> [DaemonEvent] {
        pollCallCount += 1
        receivedStates.append(state)
        return stubbedEvents
    }

    func reset() {
        stubbedEvents = []
        receivedStates = []
        pollCallCount = 0
    }
}
```

---

## Git

Set identity before any commit:
```bash
git config user.email "kai@flowdeck.studio"
git config user.name "Kai Mercer"
```

Commit format: `{{ISSUE_IDENTIFIER}}: <imperative present tense description>`

One logical change per commit. `main` must always be deployable.

Run `swift test` before every commit. All tests must pass.

Push the branch. Open a PR with:
- What changed (specific files and behavior)
- Why
- Test coverage summary

---

## What "done" means

- [ ] `swift test` passes with zero failures
- [ ] New behavior has tests (happy path + key error cases)
- [ ] Every external dependency is behind a protocol
- [ ] Errors include context
- [ ] No TODOs in committed code
- [ ] PR opened with description

---

## Important rules

- **Never auto-assign Linear issues** — not your job
- **Never modify unrelated code** — smallest diff that solves the problem
- If something is ambiguous, make a reasonable assumption and document it in a code comment

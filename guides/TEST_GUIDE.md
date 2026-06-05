# Moolah Test Guide

**Version:** 1.0
**Platform targets:** macOS 26+ (primary), iOS 26+ (secondary)

---

## 1. Philosophy: Tests Are User Stories

A test exists to describe a user-visible behaviour and to fail loudly when that behaviour breaks. A reader who is not a Swift expert should be able to open any test in the repo and understand what the system is supposed to do, without re-running anything.

This guide codifies the discipline that makes that possible. It applies to every test in the repo — store tests, contract tests, repository tests, benchmark tests, UI tests. Test-type-specific addenda live alongside it (`UI_TEST_GUIDE.md`, `BENCHMARKING_GUIDE.md`).

**Core rules:**

1. **One behaviour per test.** A test asserts one thing. If the test name needs an "and", split it.
2. **Plain-English names.** `testOpeningTradeFocusesPayee`, not `test_TDV_FocusState_Init_Trade_v2`. The name is the documentation.
3. **No sleeps. No unbounded waits. No retries.** Every wait targets a post-condition the test knows about. A test that fails intermittently is a broken test, never a "flaky" one.
4. **No test-only branches in production code.** Test modes are gated by explicit, observable launch arguments or environment variables — not `#if DEBUG` scattered through business logic.
5. **TDD for store-level tests.** Test file lands before the implementation file.
6. **Self-sufficient failures.** Readers understand what failed without re-running.

---

## 2. One Behaviour Per Test

Tests are written so a single failure points to a single cause. Each test sets up the minimum state, performs the minimum action, and asserts the minimum outcome required to verify one behaviour.

```swift
// GOOD: one behaviour, one assertion
func testPayingScheduledTransactionMarksItPaid() async throws {
    let store = try await TransactionStore.withSeededScheduledTransaction()
    _ = try await store.payScheduledTransaction(.coffee)
    XCTAssertTrue(store.transactions[.coffee].isPaid)
}

// BAD: multiple behaviours, ambiguous failure
func testPayScheduledTransactionAndUpdateNextDateAndReload() async throws { ... }
```

If two behaviours always change together, the second is part of the first behaviour's definition and belongs in a helper or driver method that the test calls — not a second assertion bolted onto a single test.

**Why.** When two behaviours share a test, a single failure can mean either is broken — the failure message is ambiguous, the cause needs guessing, the fix risks regressing the part that wasn't broken. One behaviour per test inverts that: each failure points at exactly one production change.

### Plain-English Names

Test names describe the user-visible behaviour, not the implementation:

```swift
// GOOD
func testEscapeClearsPayeeAndClosesDropdown() { ... }
func testCrossCurrencyTransferRevealsCounterpartAmount() { ... }

// BAD
func test_TXD_focus_init_v2() { ... }
func testFlow1() { ... }
```

A name that requires reading the body to interpret is broken. Rename it.

---

## 3. No Sleeps, No Unbounded Waits, No Retries

Test reliability comes from waiting for the *right* condition, not from waiting longer.

### Banned

- `Thread.sleep(...)`, `usleep`, `sleep` — fixed waits ignore the actual signal.
- `DispatchQueue.main.asyncAfter(...)` inside a test or driver to "give the UI time".
- `XCTestExpectation` with `wait(for:..., timeout: .infinity)` or no timeout.
- Retry loops, "known-flaky" markers, `XCTRetryOnFailure`-style attributes.

### Required

- Every wait targets a specific post-condition (a value, a UI element appearing, a binding propagating).
- Every wait has a bounded timeout (default 3 s for UI tests, lower for unit tests).
- A failed wait fails the test with an actionable message, not a silent retry.

```swift
// GOOD: bounded wait on a post-condition
let dropdown = app.textFields["autocomplete.payee"]
XCTAssertTrue(dropdown.waitForExistence(timeout: 3),
              "payee dropdown did not appear after 3 s")

// BAD: hope-based wait
Thread.sleep(forTimeInterval: 1.0)
XCTAssertTrue(dropdown.exists)
```

A test that requires retries is hiding a missing post-condition wait somewhere upstream. Find it and fix it.

**Why this matters more than it looks.** Every retry mechanism in a test suite gradually erodes trust in the suite as a whole. Once "the test passes on rerun" is an accepted outcome, real failures and timing flakes become indistinguishable, and reviewers stop investigating. Holding the line on "wait for a real condition, fail loudly when it doesn't happen" is how the suite stays trustworthy.

---

## 4. No Test-Only Branches in Production Code

Production code paths and test code paths must be the same paths. The exceptions are explicit, observable, single-entry test modes.

**Allowed:**

- A launch argument the test process passes explicitly (e.g. `--ui-testing`) and that the app reads exactly once at startup to swap a backend or seed deterministic data.
- An environment variable read at the same single boundary (e.g. `UI_TESTING_SEED`).
- A protocol-conforming test double injected at the dependency-injection boundary (`TestBackend` via `BackendProvider`).

**Banned:**

- `#if DEBUG` blocks scattered through business logic to "make this test pass".
- Bool flags on types that change behaviour for tests (`isUITest`, `skipNetworkInTests`).
- Test-only public properties or methods on production types.

**Why.** The point of a test is to verify the production behaviour. Once the production code branches on "am I being tested?", the test no longer covers the production path — it covers the test-only path, and the production path becomes silently uncovered. Bugs hide in the gap. Worse: every future reader of the production code has to reason about the test branch, even though it never executes in production.

The rule of thumb: if a reader of production code cannot tell whether a branch is dead in production, the branch is dead in production. Move the variation to the dependency-injection seam instead. `BackendProvider` exists for exactly this — `TestBackend` swaps in `CloudKitBackend` on an in-memory GRDB database, which is the production code path with the disk taken away.

---

## 5. TDD for Store-Level Tests

When adding a new user action that triggers a multi-step flow:

1. Write the store test first — describing the desired behaviour as a sequence of calls and assertions against `TestBackend` (in-memory `CloudKitBackend`).
2. Run the test and confirm it fails for the right reason.
3. Write the store method to make it pass.
4. Wire the view to call the store method.

Store tests use the real backend in memory; they never mock the repository. This is documented in `CLAUDE.md` under "Testing & TDD" and is non-negotiable.

UI tests are not bound to TDD order — they typically describe behaviour the store tests cannot reach (focus, overlays, keyboard handling). Write them when the store-level tests cannot exercise the failure class. See `UI_TEST_GUIDE.md` Section 1 for the test-type decision rule.

---

## 6. Self-Sufficient Failures

A failing test must give the reader enough information to understand the failure without re-running.

- **Assertion messages name the expectation.** `XCTAssertEqual(a, b, "expected balance to roll forward by deposit amount")` beats `XCTAssertEqual(a, b)`.
- **Failure artefacts persist.** UI tests dump the accessibility tree, screenshot, seed, and trace on failure (see `UI_TEST_GUIDE.md` Section 5). Store tests dump relevant repository state when an assertion fails, if the failure isn't already obvious from the message.
- **Fixtures are deterministic.** Fixed UUIDs, fixed dates, fixed payee names. A failure should reproduce on the next run unless the production code changed.

Re-running a test to "see what happened" is a sign the failure artefact is missing or wrong.

---

## 7. Capturing Test Output

Always pipe test output to `.agent-tmp/` (gitignored) so failures can be re-read without re-running:

```bash
mkdir -p .agent-tmp
just test 2>&1 | tee .agent-tmp/test-output.txt
just test TransactionStoreTests 2>&1 | tee .agent-tmp/test-output.txt
grep -B5 -A10 'failed\|error:' .agent-tmp/test-output.txt
```

Delete the temp file when done. Use descriptive names if running multiple commands in parallel (`test-mac.txt`, `test-ios.txt`, `test-ui.txt`).

This convention is also documented in `CLAUDE.md` and the Capturing Test Output section of the project README.

---

## 8. Targets and Tooling

| Target | Purpose | Backend |
| --- | --- | --- |
| `MoolahTests_macOS` | Store, contract, repository, model tests on native macOS | `TestBackend` (in-memory `CloudKitBackend`) |
| `MoolahTests_iOS` | Same suite on iOS Simulator | `TestBackend` |
| `MoolahBenchmarks` | Performance benchmarks on macOS only | `TestBackend` |
| `MoolahUITests_macOS` | XCUITest end-to-end tests on macOS only | App launched with `--ui-testing` + seeded `TestBackend` |

Every test target uses `TestBackend` — the production `CloudKitBackend` initialised against an in-memory GRDB database. No mocks at the repository layer. UI tests additionally seed the backend through fixed-UUID fixtures.

`just` targets are the only supported entry point:

```bash
just test                          # full suite, both platforms
just test-mac TransactionStoreTests # subset, macOS only
just test-ui                       # UI tests, macOS only
just benchmark                     # MoolahBenchmarks
```

---

## 9. When To Reach For Each Test Type

The cheapest test that proves the behaviour wins.

| Failure class | Test type |
| --- | --- |
| Domain logic, validation, parsing | Pure unit test (model extension or shared utility) |
| Multi-step orchestration, error rollback, computed aggregations | Store test (`MoolahTests_macOS`) |
| Repository protocol contract (sort order, filter semantics, computed values) | Contract test (`MoolahTests/Domain/`) |
| Performance regression at realistic scale | Benchmark (`MoolahBenchmarks`, see `BENCHMARKING_GUIDE.md`) |
| Sync engine event handling, conflict resolution | Sync test (`MoolahTests/Backends/CloudKit/Sync/`, see `SYNC_GUIDE.md`) |
| `@FocusState`, overlay positioning, keyboard navigation, autocomplete | UI test (see `UI_TEST_GUIDE.md`) |

A UI test is the most expensive option — slow to run, slow to author, slow to debug. Reach for it only when the failure class genuinely requires the SwiftUI event loop, focus system, or rendered overlays. Everything else belongs in a store test.

---

## 10. Checklist (every test)

- [ ] Test name describes the behaviour in plain English.
- [ ] Test asserts one behaviour.
- [ ] No `sleep`, no unbounded `wait`, no retries.
- [ ] Production code has no `#if DEBUG` test branches added for this test.
- [ ] Fixtures are deterministic (fixed UUIDs, fixed dates).
- [ ] Assertion messages are actionable.
- [ ] Test runs through a `just` target.
- [ ] (Store tests) test was written before the implementation it covers.
- [ ] (UI tests) read `UI_TEST_GUIDE.md` first.

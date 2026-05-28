---
name: writing-ui-tests
description: Use when adding or modifying a UI test in MoolahUITests_macOS, extending a screen driver under MoolahUITests_macOS or UITestSupport, adding or renaming a UI test seed in `UITestSeeds.swift`, adding an `.accessibilityIdentifier(_:)` intended for test use, or debugging a failing or flaky UI test.
---

# Writing a UI Test

Follow this checklist when adding or modifying a UI test. The guides are the source of truth — this skill orders the work and flags the cheap mistakes. Read `guides/TEST_GUIDE.md` and `guides/UI_TEST_GUIDE.md` in full before making changes; the details below assume you have.

## Before Writing

1. **Confirm a UI test is warranted.**
   - Can the behaviour be proven with a store test against `TestBackend`? Almost always, yes. If so, write the store test instead and stop.
   - UI tests earn their slot only when the failure class requires the real SwiftUI event loop: `@FocusState`, autocomplete/overlay show/hide timing, real keyboard events, multi-leg form reveal. Anything else is cheaper to cover elsewhere.
   - See `UI_TEST_GUIDE.md` §1 for the full decision table.

2. **Map the test to drivers.**
   - Sketch the test as a short user story: launch → sidebar action → list action → detail action → assertion.
   - For each step, identify the driver that owns it (`app.sidebar`, `app.transactionList`, `app.transactionDetail`, `app.dialogs`, field drivers like `AutocompleteFieldDriver`).
   - If a driver method you need does not exist, you extend the driver *first* — not the test. A test that inlines XCUI primitives to "work around a missing driver method" is wrong and the reviewer agent flags it.

3. **Pick the seed.**
   - Scan `UITestSupport/UITestSeeds.swift` for an existing seed that fits the scenario. Reuse it.
   - Only add a new seed when no existing one covers the shape (e.g., multi-leg trade baseline vs. single-leg expense baseline). New seeds use hard-coded `UUID(uuidString:)!` literals — never `UUID()`. Document the entities inline so `seed.txt` failure artefacts remain readable.

## Writing the Test

### Test file

- Location: `MoolahUITests_macOS/Tests/<Area>/<BehaviourClass>Tests.swift`.
- Class name: `<BehaviourClass>Tests` — camel-case, describes the behaviour area (e.g. `TransactionDetailFocusTests`).
- Inherits `MoolahUITestCase` — never `XCTestCase` directly. The base class wires up the four failure artefacts (`tree.txt`, `screenshot.png`, `seed.txt`, `trace.txt`).
- Imports: only `XCTest`. No `XCUIApplication`, `XCUIElement`, `XCUIElementQuery`.

### Test method

- Name: `test<BehaviourInPlainEnglish>` — `testOpeningTradeFocusesPayee`, not `test_TDV_focus_init_v2`.
- One behaviour per test. If the name needs an "and", split into two tests.
- Shape:

  ```swift
  func testOpeningTradeFocusesPayee() {
      let app = MoolahApp.launch(seed: .tradeBaseline)
      app.sidebar.switchToAccount(.checking)
      app.transactionList.openTransaction(.coffeeShop)

      app.transactionDetail.payee.expectFocused()
  }
  ```

- Body = sequence of driver actions, then driver expectations. No raw identifier strings, no `waitForExistence`, no `MoolahUITestCase` low-level primitives (`waitForIdentifier`, `typeInto`, `pressKey`).

### Extending a driver (when needed)

Each new or modified action method must:

1. Start with `Trace.record(#function, ...)` on its first line — without it, `trace.txt` cannot locate the failing step.
2. Wait for a real post-condition (an element existing, a value propagating, a focus state changing) with a bounded timeout (default 3 s). No `Thread.sleep`, no `DispatchQueue.main.asyncAfter`, no unbounded waits.
3. Fail loudly on a precondition violation (`XCTFail(...)` with the failure artefacts attached) — never silent no-ops or swallowed throws.
4. Look up elements via `MoolahApp.element(for:)` — never `app.buttons[...]`, `app.textFields[...]`, etc.
5. Reference identifiers via `UITestIdentifiers` constants — never inline string literals.
6. Not cache `XCUIElement` references on stored properties — re-resolve each call.

Expectation methods (`expect…`) never mutate state and do not call `Trace.record`.

### Adding identifiers

Add the identifier constants to `UITestSupport/UITestIdentifiers.swift` using the existing `area.element[.qualifier]` namespace, and add `.accessibilityIdentifier(UITestIdentifiers.…)` to the targeted view. Identifier additions are incremental — only what this test needs, not a bulk pass.


## After Writing

1. **Run the test in isolation**:

   ```bash
   mkdir -p .agent-tmp
   just test-ui <ClassName>/<testName> 2>&1 | tee .agent-tmp/test-ui.txt
   ```

   **From a worktree, first copy `.env` from the main checkout** (it is gitignored):

   ```bash
   cp ../../../.env .env   # adjust the path for your worktree depth
   ```

   The `.env` file pins `DEVELOPMENT_TEAM` and the code-signing identity. Without it, the worktree build is signed differently than the main checkout, so macOS treats it as a distinct app and pops a TCC prompt for Documents-folder access on first launch. That prompt blocks `XCUIApplication.launch()` indefinitely and the UI test times out with no useful artefacts. Symptom: the test hangs at launch, `tree.txt` is empty, and a system dialog is visible if you `open .agent-tmp/ui-fail-<TestName>/screenshot.png`.

2. **On failure, read artefacts before editing anything**:

   ```bash
   ls .agent-tmp/ui-fail-<TestName>/
   #   tree.txt  screenshot.png  seed.txt  trace.txt
   ```

   - `trace.txt` → find the first failing action.
   - `tree.txt` → see which identifiers actually exist at that point in the UI.
   - Fix at the right layer: missing identifier (add it), wrong seed (fix the seed), wrong driver post-condition (fix the wait), genuine product change (update the driver).
   - **Never modify the test to make a failure go away.** The test describes intended behaviour; only drivers, identifiers, and seeds change to reflect product changes.

3. **Iteration check** (a fast-feedback heuristic during driver/test iteration, *not* a substitute for the gate in step 5) — run the test three times locally:

   ```bash
   for i in 1 2 3; do
     just test-ui <ClassName>/<testName> 2>&1 \
       | tee .agent-tmp/test-ui-iter-$i.txt \
       || break
   done
   ```

   Divergence within three runs usually reveals a driver post-condition bug. Fix it before continuing.

4. **Run the `@ui-test-review` agent** on every changed file. Cheap to run; will reject things the 20-run gate would burn 20 minutes discovering. Address every finding before continuing — exceptions require a `// ui-test-review: allow <rule> — <reason>` comment with real justification.

5. **The 20-run stability gate before opening the PR** — this is the gate, not an option:

   ```bash
   for i in $(seq 1 20); do
     just test-ui <ClassName>/<testName> 2>&1 \
       | tee .agent-tmp/test-ui-run-$i.txt \
       || break
   done
   ```

   All 20 must pass. A test that fails 1-in-20 is broken, not flaky — the driver's post-condition wait is wrong. Fix it and run all 20 again from scratch. Do not open the PR with anything less than a clean 20.

## Common Mistakes

- **Writing the test first, then inlining XCUI primitives to make it compile.** Extend the driver first, always.
- **Reaching into `app.buttons[...]` because it's faster than adding a driver method.** The reviewer will flag it. So will the next test that breaks when the view restructures.
- **Bulk-adding identifiers to dozens of views "just in case".** Add only what the current test needs. Dead identifiers are a maintenance tax on everyone who comes after.
- **Catching a flake by adding a `Thread.sleep(0.5)`.** The flake is a missing post-condition wait. Find the real signal and wait on that.
- **Asserting a post-condition the driver action already owns.** `switchToAccount` returns only after the list re-rendered — the test doesn't need to re-check it. Tests assert scenario-specific outcomes, not driver contract.

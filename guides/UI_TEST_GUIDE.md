# Moolah UI Test Guide

**Version:** 1.0
**Platform targets:** macOS 26+ (UI tests are macOS-only in v1)
**Reads alongside:** `TEST_GUIDE.md` — generic test discipline that applies to every test, including UI tests.

---

## 1. When To Write A UI Test

UI tests are the most expensive tests in the repo: slow to run (each launches the app fresh), slow to author (drivers, identifiers, seeds all cost setup), slow to debug (failures involve real SwiftUI state, not just a function call). Reach for one only when the failure class **cannot** be exercised by a store test.

| Failure class | Test type |
| --- | --- |
| `@FocusState` after state changes | UI test |
| Autocomplete or overlay popup positioning, show/hide timing | UI test |
| Keyboard navigation (arrow keys, Return, Escape, Tab, Cmd-shortcuts) | UI test |
| Multi-leg form layout reveal/hide | UI test |
| Anything else (validation, orchestration, computed values, error rollback) | Store test, in `MoolahTests_macOS` |

**Why the gate is high.** Store tests run against `TestBackend` (in-memory `CloudKitBackend`) in milliseconds with no simulator and no event loop. They cover the bulk of business logic. UI tests exist to plug a single, narrow gap: SwiftUI behaviour that no amount of store testing can reach — focus state, overlay-positioned popups, real keyboard event dispatch, multi-binding interactions. Every test outside that gap is wasted slow-CI time and a future maintenance tax.

If the behaviour can be proven against `TestBackend` in a store test, write the store test instead — and stop.

### Why macOS-only

UI tests run on native macOS, never the iOS Simulator. The simulator adds boot time, animation overhead, and a different event-dispatch model that has historically been a source of flakes. macOS-native runs are an order of magnitude faster and more deterministic. iOS-specific behaviour (decimal keyboard, swipe-to-delete, navigation stack) is currently covered by manual testing — when that gap genuinely needs closing, the answer is more store tests for the underlying logic, not iOS UI tests.

---

## 2. The Screen-Driver Rule

**Inviolable:** test files import only `XCTest`. Tests never reference `XCUIApplication`, `XCUIElement`, `XCUIElementQuery`, raw identifier strings, or any other XCUI primitive. Tests are sequences of method calls on typed driver objects.

**Why.** XCUI primitives leak two kinds of fragility into tests: timing details (when to wait, what to wait for) and identifier strings (what the view renders today). Both change when the product changes — and when they do, every test that touched them breaks at the same time, far from the actual product change. The driver layer absorbs that churn: when a view is restructured, only the driver moves. The test, which describes user behaviour, stays intact.

A second motivation: tests should be readable by people who do not know XCTest. A non-Swift reviewer should be able to open the test, follow the user story, and tell whether the described behaviour is the behaviour they want. `app.transactionDetail.payee.pressEnter()` reads as English. `app.textFields["detail.payee"].typeText("\r")` does not.

```swift
// GOOD
func testArrowDownEnterSelectsPayeeSuggestion() {
    let app = MoolahApp.launch(seed: .tradeBaseline)
    app.sidebar.switchToAccount(.checking)
    app.transactionList.openTransaction(.coffeeShop)

    app.transactionDetail.payee.type("Woo")
    app.transactionDetail.payee.expectSuggestionsVisible(count: 2)
    app.transactionDetail.payee.pressArrowDown()
    app.transactionDetail.payee.expectHighlightedSuggestion(at: 0)
    app.transactionDetail.payee.pressEnter()

    app.transactionDetail.payee.expectValue("Woolworths")
    app.transactionDetail.payee.expectSuggestionsHidden()
}

// BAD: raw XCUI primitives in a test
func testBad() {
    let app = XCUIApplication()
    app.launchArguments = ["--ui-testing"]
    app.launch()
    app.textFields["detail.payee"].typeText("Woo")
    XCTAssertTrue(app.tables["autocomplete.payee"].waitForExistence(timeout: 3))
}
```

The driver hierarchy lives under `MoolahUITests_macOS/Helpers/`:

```
MoolahApp                          // owns XCUIApplication; launches with seed
├── sidebar           → SidebarScreen
├── transactionList   → TransactionListScreen
├── transactionDetail → TransactionDetailScreen
│     ├── payee        → AutocompleteFieldDriver
│     ├── amount       → AmountFieldDriver
│     ├── category     → AutocompleteFieldDriver
│     ├── date         → DatePickerDriver
│     └── leg(_:)      → LegSectionDriver (.category, .amount, .account)
└── dialogs           → DialogScreen        // error alerts, delete confirmations
```

When a needed driver method does not exist, **extend the driver first** — with a trace log line and a post-condition wait — and only then write the test that calls it. Tests never compose XCUI primitives, even temporarily.

---

## 3. Driver Invariants (the contract)

Every driver method upholds these. The `ui-test-review` agent enforces them mechanically.

### Method kinds: actions vs. expectations

- **Actions** (imperative verbs: `type`, `tap`, `pressEnter`, `switchToAccount`) perform a thing and wait for the post-condition before returning. When an action returns, the UI is in a known state.
- **Expectations** (`expect…` verbs: `expectValue`, `expectFocused`, `expectSuggestionsVisible`) assert current state. They never mutate.

No driver method returns a raw value to the test. If a test needs to know "payee equals X", it calls `expectValue("X")`.

### The six invariants

1. **Actions wait for post-conditions.** `switchToAccount(_:)` does not return until the transaction list has re-rendered for that account. `type(_:)` does not return until the text binding has propagated. The wait is bounded (default 3 s).
   *Why:* every test failure that "feels timing-related" is a missing post-condition wait somewhere. By codifying the wait inside the action, the next caller does not have to re-discover the right `waitForExistence` or guess at a `sleep`. When this invariant is upheld, retries are unnecessary by construction (Section 5, "Flaky = broken").
2. **Actions fail loudly.** Precondition violations (e.g. sidebar not visible when `switchToAccount` is called) call `XCTFail(...)` with the failure artefacts already attached. No silent no-ops, no thrown errors the caller can swallow.
   *Why:* a driver that returns silently when its precondition is wrong defers the failure to a downstream assertion that will report a confusing symptom (`expected payee to be "Foo", was ""`). Failing at the action surface keeps the trace pointing at the real cause.
3. **Expectations never mutate.** Read-only.
   *Why:* if `expectValue` could change state (e.g. by tapping to focus the field first), tests would silently re-order the UI between assertions and reproduce intermittently.
4. **Single element resolver.** All identifier lookups go through `MoolahApp.element(for:)`. One place to add logging or future retries.
   *Why:* when a future change needs to log every lookup, attach a screenshot, or change the resolution strategy, there is one site to edit. Drivers that scatter `app.textFields[...]`/`app.buttons[...]` across helpers become impossible to instrument.
5. **Stateless from the test's perspective.** Drivers re-resolve elements on each call. No cached `XCUIElement` references — they go stale after re-render.
   *Why:* SwiftUI re-creates elements on state change. A cached `XCUIElement` may target a destroyed view, producing "element not hittable" errors that look like flakes but are really stale references.
6. **First line logs to the trace.** Every action begins with `Trace.record(#function, ...)` so the failure trace shows exactly which actions ran in what order.
   *Why:* the trace is the difference between "the test failed" and "the test failed at step 4 of 7, while typing into the second leg's category field." Without it, debugging means re-running with breakpoints. With it, `trace.txt` and `tree.txt` together usually pinpoint the problem on first read.

### What goes where

- Multi-step UI sequences ("type, wait for dropdown, arrow-down, enter") → **driver**.
- Post-condition checks that belong to an action's definition ("list reloaded after account switch") → **driver** (the action would have failed otherwise; the test does not repeat the check).
- Scenario-specific assertions ("transaction is for Woolworths, $4.50") → **test**, via `expect…` driver methods.

If two tests need the same multi-step sequence, it belongs in a driver. Tests are compositions of driver calls, never of XCUI primitives.

---

## 4. Identifiers

`accessibilityIdentifier` is a separate, test-facing concern from `accessibilityLabel`. Identifiers are added to a view only when a test needs to target it — incrementally, never via an app-wide pass.

### Naming format

`area.element[.qualifier]`, lowercase, dot-separated. Centralised in `UITestSupport/UITestIdentifiers.swift`:

```
sidebar.account.<uuid>
sidebar.view.<name>                       // e.g. "upcoming", "analysis"

detail.payee
detail.amount
detail.category
detail.date
detail.leg.<legIndex>.category
detail.leg.<legIndex>.amount
detail.leg.<legIndex>.account
detail.toolbar.save
detail.toolbar.delete

autocomplete.payee                         // dropdown container
autocomplete.payee.suggestion.<index>
autocomplete.category.suggestion.<index>
autocomplete.leg.<legIndex>.category.suggestion.<index>
```

### Rules

- **No inline identifier literals.** Views call `.accessibilityIdentifier(UITestIdentifiers.detail.payee)`, never `.accessibilityIdentifier("detail.payee")`. The reviewer agent flags inline literals.
- **Identifiers do not displace labels.** `accessibilityLabel("Payee")` for VoiceOver remains. The two coexist.
- **Identifiers travel with the view.** When a view file is renamed or split, identifiers move with the elements they target — they are not coupled to file paths.
- **One namespace per area.** New areas (e.g. a future `reports.…`) extend the `UITestIdentifiers` constants struct rather than introducing a parallel naming scheme.
- **Put an identifier on a leaf, not a container.** `.accessibilityIdentifier("foryou.card")` on an outer `VStack` stamps that same id onto *every* descendant, so per-row identifiers (`foryou.row.<id>`, dismiss/view buttons) all report the container's id and the driver can't find them. Attach the container's id to a leaf inside it (e.g. its header `Text`); children then keep their own identifiers. The symptom is every element sharing one id in `tree.txt`.

---

## 5. Failure Artefacts

On any UI test failure, `MoolahUITestCase.tearDown` attaches four files to the test result and mirrors them to `.agent-tmp/ui-fail-<TestName>/` for direct inspection without spelunking `.xcresult` bundles.

**Why this regime matters.** An earlier UI testing attempt in this codebase failed when an agent could not reliably click sidebar account rows. Two root causes — *no stable identifiers* and *no introspection during failure* — combined to send debugging into a guessing spiral. Identifiers (Section 4) fix the first; the four artefacts below fix the second. With them, both humans and agents can debug a failure against the actual accessibility tree at the moment of failure, instead of guessing.

| File | Contents | Why |
| --- | --- | --- |
| `tree.txt` | Custom accessibility-tree dump. One element per line, indented by depth, columns: `identifier \| type \| label \| value \| frame \| focused?`. | Shows exactly which identifiers exist at the moment of failure — the single most important artefact. More compact and diff-friendly than `XCUIApplication.debugDescription`, which omits identifiers when empty. |
| `screenshot.png` | The full app window. | Visual confirmation of UI state. |
| `seed.txt` | Seed name and the fixtures (UUIDs, names, amounts, dates) the test started from. | Lets the reader correlate expected vs. actual state. |
| `trace.txt` | Breadcrumb of every driver action called in the test, in order, with `✓` / `✗` marks. Recorded by `Trace.record(...)` at the top of each action method. | Shows which action failed, and the exact sequence that led there. |

### The agent debugging loop

When a UI test fails:

1. Run only that test:
   ```bash
   just test-ui <ClassName>/<testName> 2>&1 | tee .agent-tmp/test-ui.txt
   ```
2. Read `.agent-tmp/ui-fail-<TestName>/trace.txt` → find the first failing action.
3. Read `.agent-tmp/ui-fail-<TestName>/tree.txt` → see which identifiers actually exist at that point.
4. Fix at the right layer:
   - Missing identifier → add via `UITestIdentifiers.swift` and the view.
   - Seed state wrong → fix the seed in `UITestSeeds.swift`.
   - Driver post-condition wrong → fix the driver's wait, not the test.
   - Genuine product change → update the driver, never the test.
5. **Never modify the test to work around a failure.** The test describes the behaviour; only the driver, identifiers, or seeds change.

**Prose `Text` surfaces in `value`, not `label`.** A SwiftUI `Text` carrying prose (a narration paragraph, a recap sentence) with an `.accessibilityIdentifier` appears in XCUITest as a text view (element type 48) whose content is in `element.value` — its `.label` is empty. A driver that matches `.label` sees `""` forever even though the text rendered. Match `value` (or both): `NSPredicate(format: "value == %@ OR label == %@", expected, expected)`. Short interactive controls (buttons, rows) still put their text in `.label`; this only bites prose. The `value` column in `tree.txt` shows which is which — for any "element exists but reads empty" failure you can't reproduce locally, read `tree.txt` first.

### Flaky = broken

There is no retry mechanism, no `flaky` flag, no `xfail`. A test that fails intermittently has a missing post-condition wait somewhere in its driver chain. Find it, name it, fix it. Section 3 invariant 1 is the contract that makes this possible.

**Why so absolute.** Retry mechanisms hide the cause of failures (the test eventually passes, so nobody investigates) while still occupying CI time and creating uncertainty about every "flaky-but-real" failure that surfaces. The discipline that keeps this suite small and reliable depends on every intermittent failure being treated as a real defect in the driver, not a known cost of doing UI tests. The moment a "rerun on failure" flag exists, every driver author has a reason not to write the harder post-condition wait.

---

## 6. Seeds

Tests start from a named seed defined in `UITestSupport/UITestSeeds.swift`:

```swift
enum UITestSeed: String {
    case tradeBaseline       // one trade transaction with two legs, fixed UUIDs
    // ...
}
```

### Rules

- **Fixed UUIDs.** Every entity in a seed has a hard-coded UUID literal. No `UUID()` calls. This makes failure artefacts diffable and lets drivers reference entities by stable name (`.coffeeShop`, `.checking`).
- **Reuse first.** Before adding a seed, check whether an existing one already covers the scenario. New seeds increase maintenance cost for every future test author.
- **One seed per scenario family.** A seed named `tradeBaseline` is for trade-related tests. Don't pile unrelated state into it.
- **Document fixtures inline.** Each seed includes a comment listing entity IDs, names, amounts, and dates. The `seed.txt` failure artefact is generated from this metadata.
- **No seeds without tests.** The reviewer agent flags seeds that are not referenced by any test.

The seed is selected via the `UI_TESTING_SEED` env var, set by `MoolahApp.launch(seed:)`. The app reads it once during startup when `--ui-testing` is present and hydrates `TestBackend` from the matching `UITestSeed`.

---

## 7. Adding A New Screen Driver

When a test needs to reach a screen no driver covers yet:

1. **File location:** `MoolahUITests_macOS/Helpers/Screens/<ScreenName>Screen.swift` (full screens) or `MoolahUITests_macOS/Helpers/Fields/<FieldName>FieldDriver.swift` (reusable field-level drivers like `AutocompleteFieldDriver`).
2. **Hang it off `MoolahApp`** as a property, mirroring `sidebar`, `transactionList`, etc.
3. **Use `MoolahApp.element(for:)`** for every identifier lookup. Do not call `app.buttons[...]` or `app.textFields[...]` directly.
4. **Required methods:**
   - At least one constructor or `expectVisible()` — proves the screen is present before any action.
   - Action methods named with imperative verbs (`tap`, `type`, `select`).
   - Expectation methods named `expect…`.
5. **Apply the six invariants** from Section 3 to every method.
6. **Add identifiers to the touched views only.** Resist the urge to bulk-add identifiers across the codebase — only the elements your driver uses get them.
7. **Run the `ui-test-review` agent** on the new driver before opening a PR.

A driver checklist:

- [ ] Action methods start with `Trace.record(#function, ...)`.
- [ ] Action methods contain at least one bounded wait, or delegate to another driver action that does.
- [ ] No `Thread.sleep`, no `DispatchQueue.main.asyncAfter`, no unbounded timeouts.
- [ ] All element lookups go through `MoolahApp.element(for:)`.
- [ ] No cached `XCUIElement` properties.
- [ ] Identifiers are referenced via `UITestIdentifiers` constants, never inline literals.
- [ ] Public methods have no test-facing parameters that leak XCUI types.

---

## 8. Running UI Tests

```bash
# All UI tests, capture output for inspection
mkdir -p .agent-tmp
just test-ui 2>&1 | tee .agent-tmp/test-ui.txt

# A single test class
just test-ui TransactionDetailFocusTests

# A single test method
just test-ui TransactionDetailFocusTests/testOpeningTradeFocusesPayee

# Loop a single test 20 times to verify stability before committing
for i in $(seq 1 20); do
  just test-ui TransactionDetailFocusTests/testOpeningTradeFocusesPayee \
    2>&1 | tee .agent-tmp/test-ui-run-$i.txt || break
done
```

A new test must pass 20 consecutive runs locally before its PR is opened. Divergence is a driver bug, not a flake — fix the post-condition wait. Twenty is the threshold because most timing-dependent bugs surface within a handful of runs; twenty consecutive successes give enough confidence that the suite will stay green in CI without producing the kind of "passes 95% of the time" rate that erodes trust.

---

## 9. Reviewer Agent

`@ui-test-review` (`.claude/agents/ui-test-review.md`) enforces this guide mechanically. Run it after creating or modifying:

- Any file under `MoolahUITests_macOS/`.
- Any view file that gains or loses an `accessibilityIdentifier(_:)` call.
- Any seed in `UITestSupport/UITestSeeds.swift`.
- Any constant in `UITestSupport/UITestIdentifiers.swift`.

The agent is an enforcer, not a substitute for understanding the rules. Read this guide first.

### Escape hatch

A `// ui-test-review: allow <rule> — <reason>` comment skips one rule on the line below it, with a written justification. This is the SwiftLint exception pattern. Exceptions are exceptional — every one is a smell that the rule or the test design is wrong.

---

## 10. Checklist (every UI test)

- [ ] Test imports only `XCTest`. No `XCUIApplication`, `XCUIElement`, `XCUIElementQuery`.
- [ ] Test class inherits `MoolahUITestCase`.
- [ ] Test body is a sequence of driver method calls — no raw identifier strings.
- [ ] Every needed identifier is in `UITestIdentifiers` (not an inline literal in a view).
- [ ] Seed is an existing one, or a new seed with fixed UUIDs and inline fixture documentation.
- [ ] Test passed 20 consecutive runs locally before the PR was opened.
- [ ] `@ui-test-review` agent run with no critical findings.

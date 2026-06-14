# Claude Code Instructions — moolah-native

## Git Workflow

**`main` is protected and does not accept direct pushes.** All changes must land via a pull request.

- **Default to a worktree.** Never make changes directly on the `main` checkout. At the start of any task that modifies files, create a git worktree on a feature branch (see the `superpowers:using-git-worktrees` skill). `.worktrees/` is gitignored.
- **Ship via PR.** Push the feature branch and open a pull request with `gh pr create`. Do not attempt `git push origin main` — it will be rejected by branch protection.
- **Exceptions:** Read-only inspection and investigation can happen on the `main` checkout without a worktree. If you're unsure whether a task will require edits, create the worktree up front.

### `EnterWorktree` refuses to nest — `ExitWorktree` first

`EnterWorktree` fails with "Already in a worktree session" if the session is **already** inside a worktree (common when a previous task's worktree is still active, or a new task arrives in an existing worktree). It refuses to create or enter a nested worktree.

`ExitWorktree` is **not** limited to worktrees created by `EnterWorktree` in the current session — calling it returns the session to the original `main` checkout regardless, leaving the old worktree's branch and files intact on disk. So the reliable sequence when you need a *different* worktree than the one you're in:

1. Create the new worktree up front with `git -C <repo> worktree add --no-track .claude/worktrees/<name> -b <branch> origin/main` (the manual fallback; do this *before* exiting so the old worktree's context is still available while you set up).
2. `ExitWorktree` with `action: "keep"` — returns the session to the `main` checkout without disturbing the old worktree.
3. `EnterWorktree` with `path:` pointing at the worktree you just created — the session switches into it cleanly.

Do **not** try to operate on a second worktree purely via absolute paths while the session CWD is stuck in the first one: skill, plan, and memory resolution all key off the session CWD, so they will silently target the wrong tree.

### Stacked-PR worktrees: don't accidentally push into the parent PR

When you create a worktree branched off another PR's head (e.g. stacking a fix-up PR on top of an open PR), `git worktree add -b <new-local> <remote-tracking-branch>` silently sets the new local branch to **track the parent's remote branch**. A subsequent `git push -u origin <new-local>` then pushes your commits *into the parent PR's branch* — overwriting or extending the wrong PR. This has happened; recovery requires a force-push to restore the parent.

To prevent it:

- **Pass `--no-track` when creating the worktree:**
  ```bash
  git -C <repo> worktree add --no-track .worktrees/<name> -b <new-local> origin/<base-branch>
  ```
- **Push with the explicit `<src>:<dst>` form** so the destination ref is unambiguous, even if upstream tracking is set wrong:
  ```bash
  git -C <worktree> push origin <new-local>:<new-local>
  ```
- Do **not** rely on `git push -u origin <new-local>` for the first push — without `--no-track` it resolves to the upstream-tracked branch, which is the parent's, not a new branch.

If you do push into the wrong branch by accident, push your commit to a new branch first to preserve the work, then force-push the parent's branch back to its previous head (verify the SHA via `gh pr view <parent> --json headRefOid` before and after).

### Xcode previews and the `mcp__xcode__RenderPreview` tool from a worktree

`mcp__xcode__RenderPreview` (and SwiftUI canvas previews in general) operate against **whichever `Moolah.xcodeproj` is currently open in Xcode**. If Xcode is open on the main checkout but you're editing a worktree, the tool will read stale source from the main checkout — newly added `#Preview` blocks won't be discoverable, and SourceKit diagnostics in the worktree may reference types as "not in scope" even though `just build-mac` from the worktree succeeds.

To use previews against a worktree:

1. `just -d <worktree-path> --justfile <worktree-path>/justfile generate` — `xcodegen` produces a per-worktree `Moolah.xcodeproj` (the project file is gitignored, so each worktree has its own).
2. Open the worktree's `Moolah.xcodeproj` in Xcode (`open <worktree-path>/Moolah.xcodeproj`). `mcp__xcode__RenderPreview` will then read from the worktree.

If the build passes from the worktree (`just build-mac`) but SourceKit / RenderPreview disagrees, the cause is usually that Xcode is still indexed against the main checkout — switch Xcode to the worktree's project before re-rendering.

## Build & Test

Always use `just` targets to ensure consistent builds and test runs:

```bash
# List all available targets
just

# Run the full test suite on iOS Simulator and macOS
just test

# Run a subset of tests (class or class/method); prefix is added per platform.
# Works for `just test`, `just test-mac`, and `just test-ios`.
just test TransactionStoreTests
just test TransactionStoreTests/testPayScheduledTransaction
just test-mac TransactionStoreTests AccountStoreTests  # multiple filters

# Build the app for macOS
just build-mac

# Build and launch the macOS app
just run-mac

# Build the app for the iOS Simulator
just build-ios

# Regenerate Moolah.xcodeproj from project.yml (run after editing project.yml)
just generate

# Apply swift-format to the repo (run before every commit)
just format

# Verify formatting (non-destructive; exits non-zero on any diff; used by CI)
just format-check
```

### Capturing Test Output

When running tests, **always pipe output to a file** in `.agent-tmp/` so you can inspect failures without re-running:

```bash
# Ensure the directory exists first
mkdir -p .agent-tmp

# Run tests and capture output
just test 2>&1 | tee .agent-tmp/test-output.txt

# Re-run only the failing class to iterate faster
just test TransactionStoreTests 2>&1 | tee .agent-tmp/test-output.txt

# Check for failures
grep -i 'failed\|error:' .agent-tmp/test-output.txt

# Get context around a specific failure
grep -B5 -A10 'testMethodName' .agent-tmp/test-output.txt
```

**Rules:**
- Always use `.agent-tmp/` for temp files (it's gitignored). Never use `/tmp`.
- Delete your temp files when you're done reviewing the results: `rm .agent-tmp/test-output.txt`
- Use descriptive filenames if running multiple test commands (e.g., `test-mac.txt`, `test-ios.txt`).

## Architecture & Constraints

- **Project Management:** Xcode project is generated by `xcodegen`. `Moolah.xcodeproj` is gitignored. Never edit `project.pbxproj` directly; edit `project.yml` and run `just generate`.
- **Targeting:** iOS 26+ and macOS 26+ (Universal SwiftUI app).
- **Domain Layer:** Strictly isolated. `Domain/Models/` and `Domain/Repositories/` must never import `SwiftUI`, `GRDB`, `URLSession`, or any backend module.
- **Features:** Only talk to repository protocols via `@Environment(BackendProvider.self)`. No feature file may import `Backends/` directly.
- **Currency & instruments:** Monetary values are modelled as `InstrumentAmount` — a `Decimal` `quantity` paired with its `Instrument` (a fiat currency, stock, or crypto token), stored as `Int64` scaled by 10^8. A profile's base currency comes from `Profile.currencyCode` (exposed as the computed `Profile.instrument`). Domain objects carry their own `InstrumentAmount`s, and views derive the instrument/currency from loaded domain objects, never from a global constant. Arithmetic across mismatched instruments traps at runtime — see `guides/INSTRUMENT_CONVERSION_GUIDE.md`. Tests use `Instrument.defaultTestInstrument` (defined in `MoolahTests/Support/Instrument+TestInstrument.swift`).
- **Monetary Sign Convention:** The sign of monetary amounts (positive or negative) is semantically important — avoid using `abs()` or otherwise discarding it. Expenses are typically negative values, but refunds are expenses with positive values. Any transaction type may have values with the opposite sign to normal. Preserve and propagate the original sign; display logic should handle both signs correctly.
- **Backend:** `BackendProvider` is the injection point. `CloudKitBackend` is the production backend — it wraps the GRDB repositories (`Backends/GRDB/`) over a per-profile SQLite database and the CKSyncEngine sync layer. `TestBackend` (CloudKitBackend backed by an in-memory GRDB database) is used in tests; `PreviewBackend` is used in SwiftUI previews.
- **CloudKit Schema:** `CloudKit/schema.ckdb` is the canonical CloudKit
  schema, hand-edited and reviewed in PRs. The Swift wire layer under
  `Backends/CloudKit/Sync/Generated/` is auto-generated by
  `tools/CKDBSchemaGen` as part of `just generate` and gitignored. See
  `guides/SYNC_GUIDE.md` §Schema Management for the architecture and the
  `modifying-cloudkit-schema` skill in `.claude/skills/` for the runbook.
- **Concurrency:** All concurrency work MUST follow `guides/CONCURRENCY_GUIDE.md`. This is not optional.
  - Mark types `@MainActor` when they own UI-bound state (e.g., Stores).
  - Use `Sendable` on all types that cross actor boundaries.
  - Prefer `async/await` over callbacks or completion handlers.
- **Performance:** Follow `guides/BENCHMARKING_GUIDE.md` for writing and interpreting benchmarks, and for signpost instrumentation patterns.

### Thin Views, Testable Stores

Views must be thin wrappers that bind state, dispatch actions, and render. **All business logic belongs in stores, model extensions, or shared utilities** — never in private view methods.

**What belongs in a Store:**
- Multi-step orchestration (e.g., create transaction → update scheduled date → reload). See `TransactionStore.payScheduledTransaction(_:)` as the reference pattern.
- Any async sequence where step N depends on step N-1 succeeding.
- Error formatting and error state management.
- Computed aggregations over domain data (e.g., available funds, filtered totals).

**What belongs in a Model extension or Shared utility:**
- Data transformation and validation (e.g., form fields → Transaction, amount text → `Decimal` quantity).
- Parsing logic (use `InstrumentAmount.parseQuantity(from:decimals:)` — never duplicate amount parsing in views).
- Computed display properties that are reused across views.

**What stays in the View:**
- `@State` bindings for local UI state (selection, sheet visibility, search text).
- Dispatching store actions (one-liner `Task { await store.doThing() }`).
- Passing the store's result to local UI state (e.g., updating `selectedTransaction` from a `PayResult`).
- SwiftUI layout, styling, and modifiers.

**Why:** Private view methods cannot be unit-tested. Logic in stores runs against `TestBackend` (CloudKitBackend + in-memory GRDB) in milliseconds with no simulator. See `plans/completed/UI_TESTING_PLAN.md` for the full audit and refactoring roadmap.

## Testing & TDD

- **Test discipline:** All tests MUST follow `guides/TEST_GUIDE.md`. UI tests additionally MUST follow `guides/UI_TEST_GUIDE.md`. Both are non-optional.
- **Write the test file before the implementation file (TDD).**
- **Contract Tests:** Every repository protocol has a contract test suite in `MoolahTests/Domain/`. Tests run against `CloudKitBackend` with an in-memory GRDB database.
- **Store Tests:** Every store method that mutates state must have tests verifying both the store's published state and the underlying repository state. Use `TestBackend` (creates `CloudKitBackend` with an in-memory GRDB database) — never mock the repository. Test error paths (rollback on failure) not just happy paths.
- **When adding a new user action** (button tap, swipe, menu item) that triggers a multi-step async flow: put the logic in the store, write the test for the store method, then wire the view to call it.
- **Targets:** `MoolahTests_iOS` (simulator), `MoolahTests_macOS` (native), `MoolahUITests_macOS` (XCUITest, macOS only — see `guides/UI_TEST_GUIDE.md`).

## Pre-Commit Checklist

**Before committing any code, you MUST:**

1. **Format and lint Swift files**
   - Run `just format` to apply `swift-format` (layout) and `swiftlint --fix` (autocorrectable idioms). Uses `.swift-format` and `.swiftlint.yml` configs.
   - CI runs `just format-check` and **will fail** if any tracked `.swift` file is not in formatted form, or if SwiftLint reports any violation (it runs `swiftlint lint --strict` with no allowlist — there is no baseline file).
   - `just format-check` is non-destructive — run it locally to preview CI's result without mutating files.
   - Xcode's editor / format-on-save can silently reformat files to a layout that disagrees with `swift-format`. Always run `just format` immediately before `git commit` so CI doesn't kick the PR back.
   - **There is no SwiftLint baseline.** The historical `.swiftlint-baseline.yml` allowlist has been fully paid down and removed; `format-check` runs `swiftlint lint --strict` against the whole tree with zero suppressed violations. If `just format-check` reports a violation, fix the underlying code: shorten the file/function/type, rename the identifier, use `#require` instead of force-unwrap, replace a tuple with a struct, etc. **NEVER reintroduce a baseline** — do not run `swiftlint --write-baseline`, do not add a `.swiftlint-baseline.yml` or a `--baseline` flag, do not silence a violation with `// swiftlint:disable` absent a real justification, and do not bump a `.swiftlint.yml` threshold to dodge a failure. Each of those launders debt instead of paying it down; the `code-review` agent treats any of them as a Critical finding.

2. **Check for Compiler Warnings**
   - Use Xcode MCP: `mcp__xcode__XcodeListNavigatorIssues` with `severity: "warning"`
   - Or run `xcodebuild` and check for warnings
   - **ALL warnings in user code must be fixed.** (Preview macro warnings from `#Preview` can be ignored.)

3. **Common Warning Fixes:**
   - **"Result of call to X is unused"**: Add `_ = ` before the call to explicitly discard the result
     ```swift
     // Before
     try await store.create(item)

     // After
     _ = try await store.create(item)
     ```
   - **"Variable 'x' was never mutated"**: Change `var` to `let`
   - **"Initialization of immutable value 'x' was never used"**: Remove unused variables

4. **Build Configuration**
   - The project is configured with `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`
   - Builds will fail if there are any warnings in user code
   - This ensures warning-free commits at all times

## Code Style & Idioms

- **Code Guide:** All Swift code MUST follow `guides/CODE_GUIDE.md`. This is not optional.
- **Tooling:** `swift-format` handles layout; SwiftLint handles policy. `just format` applies both; `just format-check` enforces them in CI.
- **Before Shipping Code:** Run the `code-review` agent (see Agents section) to validate compliance with `guides/CODE_GUIDE.md` and surface architectural issues.

## UI Design & Style Guide

- **Style Guide:** All UI work MUST follow `guides/UI_GUIDE.md`. This is not optional.
- **Apple HIG Compliance:** Follow Apple Human Interface Guidelines for macOS and iOS. When in doubt, consult the official HIG documentation.
- **macOS-First:** Optimize for desktop patterns (keyboard navigation, context menus, pointer precision), then adapt for iOS.
- **Semantic Colors:** Use system colors (`.green`, `.red`, `.secondary`) for automatic dark mode support. Never hardcode RGB values.
- **Monospaced Digits:** Always apply `.monospacedDigit()` to monetary amounts and dates.
- **Accessibility:** Every UI component must be VoiceOver-accessible with proper labels and keyboard navigation (macOS).
- **Before Shipping UI:** Run the `ui-review` agent (see Agents section) to validate compliance with `guides/UI_GUIDE.md` and identify accessibility issues.

## Bug Tracking

- **Known bugs and feature issues** are tracked as GitHub issues at https://github.com/moolah-rocks/moolah-native/issues.
- When fixing a bug, close the corresponding issue from the PR (e.g. `Fixes #123` in the commit or PR body).
- When adding a TODO or FIXME in Swift source, reference an open GitHub issue: `TODO(#N): reason — https://github.com/moolah-rocks/moolah-native/issues/N`. Bare `TODO:` / `FIXME:` without an issue reference is disallowed.
- CI blocks merging a PR that introduces a bare `TODO` or a `TODO(#N)` pointing at a closed/missing issue (`just validate-todos`). A nightly watchdog reopens any issue that gets closed while live references still exist and reconciles a `has-todos` label. See `guides/CODE_GUIDE.md` §20.

## Planning & Documentation

- **Plans Directory:** All planning documents, feature specifications, design specs, and gap analyses live in `plans/`. Completed plans are moved to `plans/completed/`. **This overrides any skill defaults** (e.g., the brainstorming skill's `docs/superpowers/specs/` path). Never create a `docs/` directory.

## Agents

This project defines specialized review agents in `.claude/agents/`. Invoke them with `@agent-name` (e.g., `@ui-review`, `@concurrency-review`).

- **`code-review`** — Reviews Swift code for `guides/CODE_GUIDE.md` compliance and architecture conventions in CLAUDE.md: naming, type choice, protocol design, error handling, optional discipline, extension organization, thin-view discipline, `TODO(#N)` format. Use after writing or significantly modifying any production Swift file, before committing.
- **`ui-review`** — Reviews SwiftUI views for `guides/UI_GUIDE.md` compliance, Apple HIG, and accessibility. Use after creating or modifying UI components.
- **`concurrency-review`** — Reviews Swift code for `guides/CONCURRENCY_GUIDE.md` compliance: actor isolation, task hygiene, Sendable, async patterns. Use after modifying stores, repositories, or backend code.
- **`sync-review`** — Reviews CKSyncEngine sync code for `guides/SYNC_GUIDE.md` compliance: error handling, change tracking, conflict resolution, account changes, zone management. Use after modifying sync engines, change trackers, or record mappings.
- **`database-schema-review`** — Reviews SQL schemas, migrations, indexes, PRAGMAs, and database lifecycle for `guides/DATABASE_SCHEMA_GUIDE.md` compliance: STRICT, indexes, FKs, retention, drop-and-recreate rules, sidecar cleanup, backup safety. Use after modifying any `DatabaseMigrator` registration, any `*Schema.swift` file, any PRAGMA configuration, or any code path that copies / removes a `*.sqlite` file. Operates pre-PR against the working tree only.
- **`database-code-review`** — Reviews Swift / GRDB code that talks to SQLite for `guides/DATABASE_CODE_GUIDE.md` compliance: records / mapping, query safety (SQL injection — only one unsafe shape), repositories, transactions, plan-pinning tests, GRDB concurrency model. Use after modifying any file under `Backends/GRDB/`, any rate / cache service that uses GRDB, any `db.execute(sql:)` / `db.execute(literal:)` site, or any test file that touches a `DatabaseQueue`. Operates pre-PR against the working tree only.
- **`instrument-conversion-review`** — Reviews Swift code for `guides/INSTRUMENT_CONVERSION_GUIDE.md` compliance: instrument-safe `InstrumentAmount` arithmetic (mismatches trap) and conversion-date correctness (historic = snapshot date, current/future = `Date()`). Use after modifying aggregation, reporting, forecast, or sidebar totals.
- **`datetime-review`** — Reviews Swift code for `guides/DATE_TIME_GUIDE.md` compliance: the timezoneless-date bug class (a `YYYYMM` month / `YYYY-MM-DD` day / chart x-position written in one zone and read in another drifts a month/day in UTC-negative zones). Verifies timezoneless values route through `Calendar.utc` / `FinancialMonth`, positioning tokens anchor at noon-UTC, parse formatters pin `en_US_POSIX`, and tests assert zone-invariance in-process — while NOT flagging values that are meant to be local (`Calendar.current` / `Date()` for "today"/"now"). Use after modifying anything that parses/formats/keys/compares a month or day, derives "today"/"this month", or builds a chart date axis.
- **`appstore-review`** — Reviews the app against App Store validation rules and Review Guidelines. Checks Info.plist, project.yml, entitlements, icons, and flags potential review issues. Use before tagging a release.
- **`ui-test-review`** — Reviews UI test code for `guides/UI_TEST_GUIDE.md` compliance: screen-driver rule (tests import only `XCTest`), driver invariants (trace logs, post-condition waits, single resolver, no element caching), identifier discipline, deterministic seeds, no sleeps/retries. Use after modifying any file under `MoolahUITests_macOS/`, any view that gains or loses an `.accessibilityIdentifier(_:)`, or any constant in `UITestSupport/`.
- **`help-review`** — Reviews user-facing help content for `guides/HELP_GUIDE.md` and `guides/BRAND_GUIDE.md` compliance: brand voice, topic-type discipline, procedure structure, banned words, UI references, microcopy (errors, empty states, tooltips, confirmations), privacy claim accuracy, accessibility, locale safety. Use after writing or modifying any help article, tooltip, empty state, error message, onboarding string, or settings description.

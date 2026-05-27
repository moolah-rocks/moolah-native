# Sidebar drag-and-drop foundation — cherry-pick from `sidebar-phase-2`

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to execute this plan task-by-task. Per project memory (`feedback_subagent_driven.md`), do not ask whether to use it — that is the default.

**Goal:** Land the view-agnostic foundation of sidebar drag-and-drop (pasteboard codec, store-side dispatch, decision-table policy, iOS `handleDrop` rewrites) on `main` as a standalone PR. Extracts the salvageable work from the paused `sidebar-phase-2` branch and discards the parts that targeted the doomed hybrid sidebar surface.

**Architecture:** Three independent additions plus an iOS clean-up:
1. `DraggableSidebarItem+Pasteboard.swift` — JSON codec mapping `DraggableSidebarItem ↔ NSPasteboardItem`. Pure value layer.
2. `SidebarDropDispatch` — `@MainActor enum` exposing `dropOntoAccount`, `dropOntoGroup`, `reorderRoot`, `reorderMembers`. Each method runs the store mutations a drop result implies. Pure orchestration over `AccountStore` / `AccountGroupStore`.
3. `SidebarDropDispatch+Policy` — pure `outcome(for:bucket:accounts:groups:)` decision-table function returning a `DropOutcome` enum. Pure data.
4. iOS `handleDrop` rewrite to call `SidebarDropDispatch` rather than re-implementing the same mutations inline.

None of these depend on the macOS view layer. They survive both the current hybrid sidebar and the imminent unified-AppKit rewrite (`plans/2026-05-27-sidebar-unified-appkit-plan.md`). The future macOS drag-wiring plan (a follow-up to the unified rewrite) hooks into all three of these from `NSOutlineViewDataSource`'s native drag methods.

**Tech stack:** Swift 6, AppKit `NSPasteboard`, existing stores, Swift Testing.

**Does not close [#991](https://github.com/moolah-rocks/moolah-native/issues/991).** That closes from the future drag-wiring follow-up plan once the macOS outline drag methods are wired into `NSOutlineViewDataSource`.

---

## Context: what we're salvaging and why

`sidebar-phase-2` (worktree: `.worktrees/sidebar-phase-2`, branch: `sidebar-phase-2`) shipped four tasks before being paused:

| Task | Commits | What it produced | Lives after the unified-outline rewrite? |
|---|---|---|---|
| 1 | `c329ef12`, `2fc85a78` | `DraggableSidebarItem+Pasteboard.swift` + 4 round-trip tests | **Yes** — view-agnostic |
| 2 | `d6babaea`, `9058073c` | `SidebarDropDispatch` + 15 store-integration tests + iOS `handleDrop` rewrite | **Yes** — view-agnostic |
| 3 | `508d60d9`, `82bd83c9`, `6241cb33` | `SidebarOutlineDropReceiver` (vendored-package conformance) **+ `+Policy.swift` decision table** + 20 tests across 2 suites + `Equatable` on `DraggableSidebarItem` | **Partial** — keep `+Policy.swift` + policy tests + `Equatable`; discard the `DropReceiver` conformance and its tests |
| 4 | `c0e43025`, `c4330dd9` | `.dragDataSource(...)` + `.onDrop(...)` wired into `SidebarOutlineView.swift` | **No** — file is deleted by the unified rewrite; reimplement against `NSOutlineViewDataSource` in the follow-up drag-wiring plan |

This plan lifts tasks 1, 2, and the keep-half of task 3 onto a fresh branch off `main`, drops task 4 entirely, and discards the original `sidebar-phase-2` branch when done.

---

## Worktree setup

- [ ] **Step 0.1: Branch from latest `main`**

  ```bash
  git -C /Users/aj/Documents/code/moolah-project/moolah-native fetch origin
  git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree add --no-track .worktrees/sidebar-drag-foundation -b sidebar-drag-foundation origin/main
  ```

  Per `feedback_no_cd_for_any_tool.md`, do not `cd` — use `git -C "$WORKTREE"` and `just -d "$WORKTREE" --justfile "$WORKTREE/justfile" <target>`. Set `WORKTREE=/Users/aj/Documents/code/moolah-project/moolah-native/.worktrees/sidebar-drag-foundation` for the rest of this plan.

- [ ] **Step 0.2: Generate and open the project**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  open "$WORKTREE/Moolah.xcodeproj"
  ```

  Per `CLAUDE.md` "Xcode previews and `RenderPreview` from a worktree" — needed if any visual check happens during this plan.

- [ ] **Step 0.3: Inspect the source commits**

  ```bash
  git -C /Users/aj/Documents/code/moolah-project/moolah-native log --oneline main..sidebar-phase-2
  ```

  Confirm the eight commit SHAs from the table above are reachable. Per `reference_macos_test_runner_hang.md`, if any earlier session left stale Moolah test-host processes, `pkill -f Moolah` before running tests in any task below.

---

## Task 1: Pasteboard codec (`DraggableSidebarItem ↔ NSPasteboardItem`)

**Files added (via cherry-pick):**
- `Features/Navigation/DraggableSidebarItem+Pasteboard.swift`
- `MoolahTests/Navigation/DraggableSidebarItemPasteboardTests.swift` (filename per Task 1's actual commit — verify with `git show`)

- [ ] **Step 1.1: Cherry-pick the Task 1 commits**

  ```bash
  git -C "$WORKTREE" cherry-pick c329ef12 2fc85a78
  ```

  If a conflict appears (shouldn't — Task 1 added new files): inspect with `git -C "$WORKTREE" status`, resolve, then `git -C "$WORKTREE" cherry-pick --continue`.

- [ ] **Step 1.2: Verify build + tests + format**

  ```bash
  mkdir -p "$WORKTREE/.agent-tmp"
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-mac
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac DraggableSidebarItemPasteboardTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-task1.txt"
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format-check
  ```

  Expected: build clean, 4/4 round-trip tests pass, format-check clean.

  If the test filename in the cherry-picked commit differs from `DraggableSidebarItemPasteboardTests`, substitute the real name in the filter.

---

## Task 2: `SidebarDropDispatch` + iOS `handleDrop` rewrite

**Files affected (via cherry-pick):**
- `Features/Navigation/SidebarDropDispatch.swift` (new — exact path per the actual commit; verify with `git show d6babaea --stat`)
- `MoolahTests/Navigation/SidebarDropDispatchTests.swift` (new, 15 tests)
- Whatever support file Task 2 added for shared test fixtures
- `Features/Navigation/SidebarView+Groups.swift` (iOS `handleDrop` rewritten as thin wrapper)
- Possibly new methods on `AccountStore` / `AccountGroupStore` (depending on Task 2's design)

- [ ] **Step 2.1: Cherry-pick the Task 2 commits**

  ```bash
  git -C "$WORKTREE" cherry-pick d6babaea 9058073c
  ```

- [ ] **Step 2.2: Verify**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-mac
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-ios
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarDropDispatchTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-task2.txt"
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format-check
  ```

  Expected: macOS + iOS build clean, 15/15 dispatch tests pass, format-check clean.

  Per Task 2's design note in the source summary: `reorderRoot` uses per-entry position writes (not batched) because batching would silently flip the standalone/group tie-break. The cherry-picked test suite enforces this — do not "optimise" it.

---

## Task 3: Policy decision table — keep the policy, drop the receiver

This is the surgical cherry-pick. Task 3 produced two halves on the same commits: a vendored-package `DropReceiver` conformance (doomed — the package is deleted by the unified rewrite) and a pure decision-table policy + 20 tests (survives). We bring it all in, then delete the doomed half in a follow-up commit so the policy + tests land on a clean foundation.

**Files we want to keep:**
- `Features/Navigation/SidebarOutlineDropReceiver+Policy.swift` (or wherever Task 3 placed the `outcome(for:bucket:accounts:groups:)` decision-table extension — verify with `git show 508d60d9 --stat`)
- The `Equatable` conformance added to `DraggableSidebarItem`
- The policy test suite (probably named `SidebarOutlineDropReceiverPolicyTests` or similar)

**Files we want to drop:**
- `Features/Navigation/SidebarOutlineDropReceiver.swift` (or wherever the `DropReceiver`-conforming class lives — its protocol disappears with the vendored package)
- The receiver-conformance test suite (probably named `SidebarOutlineDropReceiverTests` or similar)

- [ ] **Step 3.1: Confirm exact filenames before cherry-picking**

  ```bash
  git -C /Users/aj/Documents/code/moolah-project/moolah-native show 508d60d9 --stat
  git -C /Users/aj/Documents/code/moolah-project/moolah-native show 82bd83c9 --stat
  git -C /Users/aj/Documents/code/moolah-project/moolah-native show 6241cb33 --stat
  ```

  Note the filenames and which commit introduced each. If the receiver class and the `+Policy.swift` extension live in the same commit, the surgical-delete strategy below applies; if they're in separate commits, just cherry-pick the policy commits and skip the receiver ones.

- [ ] **Step 3.2: Cherry-pick all three Task 3 commits**

  ```bash
  git -C "$WORKTREE" cherry-pick 508d60d9 82bd83c9 6241cb33
  ```

  Resolve any conflict from the receiver class referencing `DropReceiver` (the vendored package is still present on `main`-as-of-this-cherry-pick — there should be no conflict at this step).

- [ ] **Step 3.3: Delete the receiver class + its conformance tests**

  Replace `<receiver-class-path>` and `<receiver-tests-path>` with the actual paths surfaced in Step 3.1.

  ```bash
  git -C "$WORKTREE" rm <receiver-class-path>
  git -C "$WORKTREE" rm <receiver-tests-path>
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" generate
  ```

- [ ] **Step 3.4: If the receiver class was wired into `SidebarOutlineView.swift`, unwire it**

  Task 4 wired `.onDrop(of: ..., receiver: SidebarOutlineDropReceiver(...))` into `SidebarOutlineView.swift`. We are **not** cherry-picking Task 4 — so that file should not reference `SidebarOutlineDropReceiver` on this branch. Confirm:

  ```bash
  grep -rn "SidebarOutlineDropReceiver" "$WORKTREE/Features"
  ```

  Expected: zero matches outside `+Policy.swift` (the policy file may carry the receiver name as a namespace prefix — that's a rename candidate; address in Step 3.6).

- [ ] **Step 3.5: Build + test + format**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" build-mac
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac SidebarOutlineDropReceiverPolicyTests 2>&1 | tee "$WORKTREE/.agent-tmp/test-task3-policy.txt"
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format-check
  ```

  Expected: build clean, ~20/20 policy tests pass, format-check clean. If the policy tests can't compile because they import something the receiver class owned, lift the missing piece into `+Policy.swift` itself.

- [ ] **Step 3.6: Optional rename — `SidebarOutlineDropReceiver+Policy.swift` → `SidebarDropPolicy.swift`**

  Now that the `DropReceiver` class no longer exists, the file/type prefix becomes archaeology. If `outcome(for:bucket:accounts:groups:)` is currently a static method on `SidebarOutlineDropReceiver`, lift it into a dedicated `enum SidebarDropPolicy` and rename the file. Update the policy test suite to reference the new namespace. Re-run Step 3.5 to confirm green.

  Skip this step if the names are already neutral.

- [ ] **Step 3.7: Commit the deletion (+ optional rename) as one logical change**

  ```bash
  git -C "$WORKTREE" add -A
  git -C "$WORKTREE" commit -m "refactor(sidebar): drop vendored DropReceiver conformance; keep policy"
  ```

---

## Task 4: Full-suite verification

- [ ] **Step 4.1: Run the entire macOS unit + UI suite**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-mac 2>&1 | tee "$WORKTREE/.agent-tmp/test-mac.txt"
  grep -i 'failed\|error:' "$WORKTREE/.agent-tmp/test-mac.txt"
  ```

  Expected: all 3445+ macOS tests (3445 was the count after Phase 2 Task 4; this branch carries Tasks 1–3 only, so the exact count will be slightly lower) pass. Investigate any failure — drag-related XCUITests from Phase 2 should not be present yet, so failures point at something the cherry-pick broke.

- [ ] **Step 4.2: Run the iOS suite to verify the `handleDrop` rewrite**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" test-ios 2>&1 | tee "$WORKTREE/.agent-tmp/test-ios.txt"
  grep -i 'failed\|error:' "$WORKTREE/.agent-tmp/test-ios.txt"
  ```

  Expected: green. iOS sidebar drag-and-drop still works via the same UI surface; the implementation is now routed through `SidebarDropDispatch`.

- [ ] **Step 4.3: Confirm `format-check` is clean**

  ```bash
  just -d "$WORKTREE" --justfile "$WORKTREE/justfile" format-check
  ```

  Per `feedback_swiftlint_fix_not_baseline.md` — if a SwiftLint violation appears, fix the underlying code, do not bump thresholds.

---

## Task 5: Review pass

- [ ] **Step 5.1: Run `@code-review` on the foundation**

  Focus areas:
  - Is `outcome(for:...)` truly side-effect-free?
  - Does `SidebarDropDispatch` correctly preserve the per-entry position write semantics flagged in Phase 2's notes?
  - Did the receiver-class deletion leave any dead imports / stale doc comments behind?

- [ ] **Step 5.2: Run `@concurrency-review`**

  `SidebarDropDispatch` is `@MainActor` (per Phase 2's design). Verify all callers (the iOS `handleDrop` rewrites) reach it from `@MainActor` context.

- [ ] **Step 5.3: Apply findings**

  Per `feedback_apply_all_review_findings.md`: Critical / Important / Minor all get fixed. Do not defer Minor without asking.

  Commit fixes as small, logical commits — not one rollup.

---

## Task 6: PR

- [ ] **Step 6.1: Push the branch**

  Per `CLAUDE.md` "Stacked-PR worktrees: don't accidentally push into the parent PR" — even though this branch is off `main` (not a stack), use the explicit `src:dst` form:

  ```bash
  git -C "$WORKTREE" push origin sidebar-drag-foundation:sidebar-drag-foundation
  ```

- [ ] **Step 6.2: Open the PR**

  ```bash
  gh pr create --title "Sidebar drag-and-drop foundation (pasteboard codec, dispatch, policy)" --body "$(cat <<'EOF'
## Summary

Lands the view-agnostic foundation of sidebar drag-and-drop. Salvaged from the paused `sidebar-phase-2` branch; the view-wiring half of that branch is discarded in favour of the unified-AppKit sidebar rewrite landing in parallel.

- `DraggableSidebarItem ↔ NSPasteboardItem` JSON codec.
- `@MainActor enum SidebarDropDispatch` — `dropOntoAccount`, `dropOntoGroup`, `reorderRoot`, `reorderMembers`.
- `SidebarDropPolicy.outcome(for:bucket:accounts:groups:)` decision-table function.
- iOS `handleDrop` rewritten as thin wrappers over `SidebarDropDispatch`.

Does **not** close [#991](https://github.com/moolah-rocks/moolah-native/issues/991) — drag wiring against the macOS outline ships in a follow-up plan (`plans/2026-05-2X-sidebar-drag-wiring-plan.md`, to be written after the unified-AppKit sidebar lands).

## Test plan

- [ ] `just test-mac` green
- [ ] `just test-ios` green (verifies iOS `handleDrop` rewrite)
- [ ] `just format-check` clean
- [ ] iOS sidebar drag-and-drop still works manually (drop account onto account = create group; drop into group = add; reorder)

## Coordination

- Sibling PR: unified-AppKit macOS sidebar (`plans/2026-05-27-sidebar-unified-appkit-plan.md`). Independent — disjoint file set. Either can merge first.
- Follow-up PR: drag-wiring against the unified outline. Depends on both this PR and the unified-AppKit PR.
EOF
)"
  ```

- [ ] **Step 6.3: Enable automerge**

  Per `feedback_prs_to_merge_queue.md`: use the landing-prs skill / `gh pr merge --auto --rebase`. Per `feedback_pr_ci_gate_when_ui_host_blocked.md`: if the local UI host is wedged, gate on the PR's CI before merging.

---

## Task 7: Clean up the paused `sidebar-phase-2` worktree

Only run this after the foundation PR has merged.

- [ ] **Step 7.1: Confirm the foundation PR is merged**

  ```bash
  gh pr view sidebar-drag-foundation --json mergedAt
  ```

  Expected: non-null `mergedAt`.

- [ ] **Step 7.2: Remove the paused worktree + branch**

  ```bash
  git -C /Users/aj/Documents/code/moolah-project/moolah-native worktree remove .worktrees/sidebar-phase-2 --force
  git -C /Users/aj/Documents/code/moolah-project/moolah-native branch -D sidebar-phase-2
  ```

  The `--force` is intentional — the worktree carries committed-but-not-merged work, but every salvageable commit was already cherry-picked. The doomed commits (Task 4's `SidebarOutlineView.swift` wiring; Task 3's `SidebarOutlineDropReceiver` class) are discarded by design.

  Per the project's "Executing actions with care" guidance — destructive operations need user confirmation. **Pause here and confirm with the user that the cherry-pick captured everything they want preserved before deleting the branch.**

---

## Self-review checklist

- **Spec coverage:** Every salvageable Phase 2 task (1, 2, 3-keep-half) maps to a task in this plan. Task 4 and the discarded half of Task 3 are documented in Context with the rationale for dropping them.
- **Type consistency:** `SidebarDropDispatch`, `SidebarDropPolicy` (post-rename), `DraggableSidebarItem`, `DropOutcome` — same names across tasks.
- **Placeholder scan:** Two `<receiver-class-path>` / `<receiver-tests-path>` placeholders in Task 3 are intentional and resolved in Step 3.1 via `git show`.
- **Destructive-action discipline:** Task 7's `worktree remove --force` + `branch -D` pauses for user confirmation, per CLAUDE.md and personal "Executing actions with care."
- **Branch protection:** all commits land on `sidebar-drag-foundation`, not `main`; PR is opened via `gh pr create --base main`.

---

## Execution

Per project memory `feedback_subagent_driven.md`, dispatch via `superpowers:subagent-driven-development` without asking.

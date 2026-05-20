# AppleScript `txn` Rename — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to implement this plan task-by-task. Per-task verify includes `just format-check` plus the live AppleScript repros listed in the verification task.

**Spec:** `plans/2026-05-21-applescript-txn-rename-design.md` (commit `e5815c86`).
**Issue:** [#923](https://github.com/ajsutton/moolah-native/issues/923).

**Goal:** Rename the AppleScript `transaction` class to `txn` in `Moolah.sdef` so the bare class term parses (the previous name was poisoned by AppleScript's reserved `transaction` keyword from System Events). Four-char code `Txn ` and all Swift handlers stay untouched.

**Architecture:** Five-line edit in the `.sdef` (class name, profile element, create command name, two result types) plus a doc sweep in `automate-app/SKILL.md`. Cocoa keys / Swift classes are unchanged; the bridge to `Moolah.ScriptableTransaction` etc. still works through the unchanged four-char codes and cocoa-key strings.

**Tech Stack:** Apple Cocoa Scripting (`.sdef`), bundled into the macOS app at build time. Verification is via the live app using `.claude/skills/automate-app/scripts/moolah-tell`.

---

## File Structure

**Modify:**

- `Automation/AppleScript/Moolah.sdef` — five terminology edits (class `name=` / `plural=`, profile `<element type=>`, `create transaction` command `name=`, two `<result type=>` attributes).
- `.claude/skills/automate-app/SKILL.md` — replace the obsolete `#923` caveat with a short rename note; rewrite every example using `transaction` / `transactions` to `txn` / `txns`.
- `Automation/AppleScript/Commands/ResetImportCommand.swift` — drop the stale "shadow workaround" doc comment that justified the command's existence.

**Create:** None.

**Out of scope:**

- No Swift handler code changes. The `@objc var transactionType` on `ScriptableTransaction`, the `CreateTransactionCommand` class, etc. all keep their names.
- No four-char code changes — `Txn `, `Mtty`, `Maty`, `Moolcrtx`, all unchanged. Compiled `.scpt` files referencing the codes continue to resolve.
- No `project.yml`, no CloudKit/GRDB schema, no unit-test changes.

---

## Task 1 — Rename the class and related terminology in the sdef

**File:** `Automation/AppleScript/Moolah.sdef`

### Steps

- [ ] **Step 1: Read the current state.**

Open `Automation/AppleScript/Moolah.sdef` and locate the five edit sites. (If unrelated commits land on main while this PR is in flight, the line numbers may shift; grep for the exact strings before each edit rather than relying on positional offsets.)

- [ ] **Step 2: Rename the class declaration (around line 88).**

Replace:

```xml
    <class name="transaction" code="Txn " description="A financial transaction." plural="transactions">
```

with:

```xml
    <class name="txn" code="Txn " description="A financial transaction." plural="txns">
```

The four-char code (`Txn `), the description, and the `<cocoa class="Moolah.ScriptableTransaction"/>` child stay exactly as-is. Only `name=` and `plural=` change.

- [ ] **Step 3: Rename the element on the `profile` class (around line 51).**

Replace:

```xml
      <element type="transaction" access="r">
        <cocoa key="scriptableTransactions"/>
      </element>
```

with:

```xml
      <element type="txn" access="r">
        <cocoa key="scriptableTransactions"/>
      </element>
```

Only `type="transaction"` → `type="txn"`. The cocoa key stays `scriptableTransactions` (it's the Swift binding key — that property exists on `ScriptableProfile` in Swift).

- [ ] **Step 4: Rename the `create transaction` command (around line 175).**

Replace:

```xml
    <command name="create transaction" code="Moolcrtx" description="Create a new transaction in a profile.">
      <cocoa class="Moolah.CreateTransactionCommand"/>
```

with:

```xml
    <command name="create txn" code="Moolcrtx" description="Create a new txn in a profile.">
      <cocoa class="Moolah.CreateTransactionCommand"/>
```

The cocoa class (Swift) stays. The four-char code (`Moolcrtx`) stays. Only the human term and the description's word change.

- [ ] **Step 5: Rename the result type on `create transaction` (around line 196).**

Replace:

```xml
      <result type="transaction" description="The created transaction."/>
```

with:

```xml
      <result type="txn" description="The created txn."/>
```

- [ ] **Step 6: Rename the result type on `pay` (around line 236).**

Replace:

```xml
      <result type="transaction" description="The paid transaction."/>
```

with:

```xml
      <result type="txn" description="The paid txn."/>
```

- [ ] **Step 7: Sanity-grep the modified sdef.**

```bash
grep -nE 'type="transaction"|name="transaction"|name="create transaction"' Automation/AppleScript/Moolah.sdef
# Expected: no matches.

grep -cE 'type="txn"|name="txn"|name="create txn"' Automation/AppleScript/Moolah.sdef
# Expected: 4
#   - 1 × class name="txn"
#   - 1 × element type="txn" on profile
#   - 1 × command name="create txn"
#   - 2 × result type="txn"  (create txn + pay)
# Total: 5 — but `name=` matches only count as one of the "name=…" tests; the
# four-line count = 1(class) + 1(element) + 1(command) + 2(results) = 5.
# If the count is 4, you missed one site. If 6+, an unrelated `type="txn"`
# slipped in.

grep -E 'plural="transactions"' Automation/AppleScript/Moolah.sdef
# Expected: no matches (the plural is now "txns").
```

If any of these come back with the wrong count, locate the missing or extra edit and fix it before moving on.

- [ ] **Step 8: Build the macOS app.**

```bash
just build-mac
```

Expected: `** BUILD SUCCEEDED **`, no warnings. The sdef is XML — xcodebuild's resource-copy step parses it during build and will flag malformed XML.

- [ ] **Step 9: Verify the bundled sdef.**

```bash
grep -E 'name="(transaction|txn)"' .DerivedData-mac/Build/Products/Debug/Moolah.app/Contents/Resources/Moolah.sdef
# Expected: exactly one match — name="txn" on the class.
# `name="transaction"` should NOT appear anywhere.
```

- [ ] **Step 10: format-check.**

```bash
just format-check
```

Expected: `All Swift files are correctly formatted.` (non-Swift files pass through.)

- [ ] **Step 11: Commit.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/applescript-shadow-923 add Automation/AppleScript/Moolah.sdef
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/applescript-shadow-923 commit -m "fix(applescript): rename transaction class to txn (#923)

The word 'transaction' is reserved in the AppleScript language itself
(System Events ships begin/end/abort transaction in its 'misc' suite),
so the bare class term could never resolve in 'every transaction',
'transaction id', or 'whose' contexts — the parser tokenises it as a
keyword. Confirmed by reproducing the same -2741 'Expected class name
but found transaction' error inside tell application 'Finder' with no
Moolah involved.

Rename the class to 'txn' (and 'transactions' → 'txns', 'create
transaction' → 'create txn'). Four-char codes (Txn , Moolcrtx) and
cocoa keys / class names (Moolah.ScriptableTransaction, Moolah.Create
TransactionCommand, transactionType, scriptableTransactions) are all
unchanged; only the AppleScript-visible terms move. Compiled scripts
using the codes continue to resolve.

Fixes #923."
```

---

## Task 2 — Update the `automate-app` skill doc

**File:** `.claude/skills/automate-app/SKILL.md`

### Steps

- [ ] **Step 1: Find the existing #923 caveat block.**

Open `.claude/skills/automate-app/SKILL.md` and find the block starting `> **Caveat — the singular \`transaction\` class term is shadowed.**` (around line 139, runs through ~line 148).

- [ ] **Step 2: Replace the caveat with a rename note.**

Replace the whole block with:

```markdown
> **The transaction class is named `txn` in AppleScript.** The word
> "transaction" is reserved in AppleScript itself (System Events ships
> `begin transaction`/`end transaction`/`abort transaction` in its
> `misc` suite), so the bare class term cannot resolve as a class name
> in `every transaction`/`transaction id "…"`/`whose` contexts —
> the parser tokenises it as a keyword. Use `txn` instead:
> `every txn of profile "…" whose id is "…"`,
> `delete txn id "…" of profile "…"`,
> `count txns of profile "…"`,
> `create txn in profile "…" with payee "…" amount …`. The four-char
> code `'Txn '` is unchanged, so compiled `.scpt` files keep working.
> Fixed in [#923](https://github.com/ajsutton/moolah-native/issues/923).
```

Preserve one blank line before and after.

- [ ] **Step 3: Rewrite every example in the doc that uses `transaction` or `transactions`.**

First, locate every example:

```bash
grep -n -E '\btransaction[s]?\b' .claude/skills/automate-app/SKILL.md
```

For each line, decide whether the use is a code/example reference (should change to `txn`/`txns`) or prose narrative (leave alone or rephrase as needed). Be specific:

| Old text in example | New text |
|---|---|
| `count transactions of profile` | `count txns of profile` |
| `every transaction of profile` | `every txn of profile` |
| `delete transaction id "…"` | `delete txn id "…"` |
| `create transaction in profile` | `create txn in profile` |
| `get {payee, amount} of every transaction` | `get {payee, amount} of every txn` |
| `pay <transaction-specifier>` | `pay <txn-specifier>` |

Prose like "the transaction subsystem" or "transaction history" describing user-facing concepts can stay — those don't refer to the AppleScript term. Use judgement; keep the doc readable.

- [ ] **Step 4: Re-grep to confirm.**

```bash
grep -n -E '\btransaction[s]?\b' .claude/skills/automate-app/SKILL.md
```

Inspect the remaining hits. Only the new caveat-replacement note (which mentions the reserved word) and any pure-prose uses should remain. No example commands should still use the old terms.

- [ ] **Step 5: Sanity-grep the repo for any other consumer.**

```bash
grep -rn -E '\bcreate transaction\b|every transaction|count transactions|delete transaction' \
  .claude/skills/ Automation/ plans/ guides/ 2>/dev/null \
  | grep -v 'plans/2026-05-21-applescript-txn-rename'
```

The plan and spec for this work are excluded by the `grep -v`. Any other match is a stale reference to update. If a Swift doc-comment mentions an AppleScript example using the old terms, update it. Common sites:
- `Automation/AppleScript/Commands/*.swift` — class-level doc comments often quote the AppleScript form they handle.
- `guides/` — may have user-facing automation doc.

- [ ] **Step 6: format-check.**

```bash
just format-check
```

- [ ] **Step 7: Commit.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/applescript-shadow-923 add .claude/skills/automate-app/SKILL.md
# If you also updated other docs (Step 5), add them in the same commit:
# git -C <worktree> add <other-files>
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/applescript-shadow-923 commit -m "docs(automate-app): switch examples from transaction to txn (#923)

The AppleScript class was renamed to txn (Task 1). Update every example
in the skill doc to the new term, and replace the shadow caveat with a
short note pointing scripters at the rename and the underlying
reserved-word cause."
```

---

## Task 3 — Drop the stale ResetImport doc comment

**File:** `Automation/AppleScript/Commands/ResetImportCommand.swift`

### Steps

- [ ] **Step 1: Read the current doc comment.**

The doc comment above `class ResetImportCommand` previously justified the command as a workaround for the shadow bug (it said per-transaction id specifiers couldn't be used because of the shadow). That justification is obsolete now — `delete txn id "…"` works.

- [ ] **Step 2: Trim the comment to describe what the command does, not why it was needed.**

Locate the comment block above `class ResetImportCommand`. Keep the "Handles: …" line and the description of what the command does. Drop any lines that read like "we needed this because the per-id specifier was broken". If the surviving comment reads naturally, leave it alone — minimal edits only.

Suggested final shape (adapt to whatever the surviving text needs):

```swift
  /// Handles: `reset import of account "Coinstash" of profile "X"`
  ///
  /// Deletes every transaction with a leg on the account so a subsequent
  /// `synchronize` re-imports it from scratch.
```

- [ ] **Step 3: Build and format-check.**

```bash
just build-mac
just format-check
```

Expected: clean.

- [ ] **Step 4: Commit.**

```bash
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/applescript-shadow-923 add Automation/AppleScript/Commands/ResetImportCommand.swift
git -C /Users/aj/Documents/code/moolah-project/moolah-native/.claude/worktrees/applescript-shadow-923 commit -m "docs(applescript): drop stale shadow justification from ResetImportCommand (#923)

The command was originally framed as a workaround for the bare-class
shadow. The shadow is gone (Task 1 renamed the class to txn). Trim
the doc comment to describe what the command does, not why we used to
need it. The command itself stays — it's still a useful bulk-clear
primitive for synced-account testing."
```

---

## Task 4 — End-to-end verification against the running app

**Files:** none modified.

### Steps

- [ ] **Step 1: Build and launch.**

```bash
just build-mac
pkill -f 'Moolah.app' 2>/dev/null || true
just run-mac &
sleep 5
```

(Kill stale Moolah processes first per memory `reference_macos_test_runner_hang.md`.)

- [ ] **Step 2: List profiles and pick one with at least one transaction.**

```bash
.claude/skills/automate-app/scripts/moolah-tell 'get name of every profile'
```

Pick a profile (prefer "Large Test Profile" if listed) — call its name `<profile>` in the steps below.

- [ ] **Step 3: Confirm the new bare-class form parses (the primary acceptance criterion for #923).**

```bash
.claude/skills/automate-app/scripts/moolah-tell \
  'get id of every txn of profile "<profile>"'
```

Pass condition: parses, returns a list of UUIDs. **If this still errors with `-2741 Expected class name but found "txn"`, the rename did not take. Stop, re-check the sdef, rebuild.**

Save the first UUID as `<uuid>` for the next steps.

- [ ] **Step 4: Run the issue's three previously-failing repros with the new term.**

```bash
# Repro 1 — predicate addressing
.claude/skills/automate-app/scripts/moolah-tell \
  'every txn of profile "<profile>" whose id is "<uuid>"'
# Expected: a list of one reference.

# Repro 2 — id-addressed delete with a FAKE uuid (parse-only check; we do
# not actually want to delete a real row in the test profile)
.claude/skills/automate-app/scripts/moolah-tell \
  'delete txn id "00000000-0000-0000-0000-000000000000" of profile "<profile>"'
# Pass condition: parses; runtime "no such object" or silent success are
# both acceptable. -2741 is NOT acceptable.

# Repro 3 — every-id (also covered in Step 3, but logged here for the
# verification record).
.checked-as-step-3
```

- [ ] **Step 5: Negative-control — confirm the old `transaction` term now errors at a parser level.**

```bash
.claude/skills/automate-app/scripts/moolah-tell \
  'get id of every transaction of profile "<profile>"' 2>&1 | head -3
```

Expected: still errors with `-2741 Expected class name but found "transaction"` (or similar). This confirms we actually changed the term — not just added an alias. If THIS form mysteriously starts working, something else changed.

- [ ] **Step 6: Regression check — previously-working plural / aggregate forms work with the new plural.**

```bash
.claude/skills/automate-app/scripts/moolah-tell \
  'count txns of profile "<profile>"'
# Expected: a positive integer.

.claude/skills/automate-app/scripts/moolah-tell \
  'get {payee, amount} of every txn of profile "<profile>"'
# Expected: a list of payee/amount pairs.
```

- [ ] **Step 7: Verify `create txn` still works.**

```bash
.claude/skills/automate-app/scripts/moolah-tell \
  'create txn in profile "<profile>" with payee "Plan Test" amount -1.23 account "<account-name>"'
# Expected: returns a txn reference. Pick `<account-name>` from the
# profile's accounts (e.g. `get name of every account of profile "X"`).
```

(Optional: clean up the test row afterwards via `delete txn id "…" of profile "…"` using the returned UUID.)

- [ ] **Step 8: Quit the app.**

```bash
.claude/skills/automate-app/scripts/moolah-tell 'quit'
```

- [ ] **Step 9: No commit — Task 4 is a verify pass only.**

If anything in Steps 3-7 produces a `-2741` parse error on a NEW (`txn`) form, return to Task 1 and inspect the sdef. The most common cause of a partial-rename: missing one of the five edit sites in the sdef. The grep counts in Task 1 step 7 are the safety net for that.

---

## Spec Coverage Check (self-review)

| Spec Section | Implemented In |
|---|---|
| Class `transaction` → `txn` rename | Task 1 steps 2-3 |
| `create transaction` → `create txn` | Task 1 step 4 |
| Result-type renames (`create txn` + `pay`) | Task 1 steps 5-6 |
| Plural `transactions` → `txns` | Task 1 step 2 |
| Four-char code unchanged | Enforced by Task 1's edit instructions (only `name=` / `plural=` / `type=` change). |
| Cocoa class / cocoa key unchanged | Enforced by the same instructions. |
| SKILL.md caveat replacement | Task 2 step 2 |
| Doc example sweep | Task 2 step 3-5 |
| Drop stale ResetImport justification | Task 3 |
| Live verification of previously-failing repros | Task 4 steps 3-4 |
| Negative-control of old term | Task 4 step 5 |
| Regression of plural / aggregate forms | Task 4 step 6 |
| `create txn` still works | Task 4 step 7 |

## Placeholder & Consistency Scan

- No TBDs / TODOs in the plan body.
- The new class name (`txn`), plural (`txns`), command (`create txn`), and four-char code (`Txn `) are used consistently across all tasks.
- File paths absolute or repo-rooted; git commands use `git -C <worktree>` explicitly per the project rule.

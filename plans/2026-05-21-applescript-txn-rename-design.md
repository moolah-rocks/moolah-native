# AppleScript `transaction` Class Rename to `txn` (#923)

**Issue:** [#923](https://github.com/ajsutton/moolah-native/issues/923).
**Status:** Design — not yet implemented.
**Date:** 2026-05-21.

## Problem

`Automation/AppleScript/Moolah.sdef` defines a class with `name="transaction"`.
The word "transaction" is **reserved in the AppleScript language itself** —
System Events ships three compound commands using it (`begin transaction`,
`end transaction`, `abort transaction`, from the `misc` suite). The
AppleScript parser tokenises any bare `transaction` as a keyword, not a
class-name token. As a result, every specifier that asks for `transaction`
in a class-name position fails to parse:

```
get id of every transaction of profile "X"
   → syntax error: Expected class name but found "transaction". (-2741)
every transaction of profile "X" whose id is "<uuid>"
   → syntax error.
delete transaction id "<uuid>" of profile "X"
   → syntax error.
```

The same error reproduces inside `tell application "Finder"` with no
Moolah involved at all, confirming the term is poisoned globally and not
by anything Moolah does in its terminology table.

This makes the singular class addressing — the canonical way to delete or
mutate one row by id, or to filter a list by a `whose` predicate — entirely
unavailable for transactions. Other Moolah classes (`account`, `earmark`,
`category`) work fine: their human terms are not reserved.

## Initial Misdiagnosis (Recorded for Context)

The issue text and an earlier draft of this spec hypothesised that the
problem was the `transaction type` property's name shadowing the class
term, and proposed renaming `transaction type` → `type`. That fix was
implemented and verified against the running app — it had no effect on
the parse error. The property rename was a defensible cleanup (the new
`type` is consistent with `leg.type`) but not the cause of #923. Reverted
before this revised spec.

The actual root cause was found by removing each of `create transaction`,
`<result type="transaction">`, and other transaction-touching terminology
in turn and confirming no change in parser behaviour. The parse error
reproduces against Finder, so the reservation is in the AppleScript
language, not in Moolah's dictionary.

## Goal

Make every singular `transaction`-class specifier parse correctly —
including the bare class form in `every X`, `X id "…"`, and
`X whose …` positions — without touching the Swift handlers
(`ScriptableTransaction`, `CreateTransactionCommand`, etc.) and without
changing the four-char code (`Txn `) that compiled scripts may depend on.

## Fix

Rename the class in `Automation/AppleScript/Moolah.sdef`:

| Was | Becomes |
|---|---|
| `<class name="transaction" code="Txn " plural="transactions">` | `<class name="txn" code="Txn " plural="txns">` |
| `<element type="transaction" …>` on `profile` | `<element type="txn" …>` |
| `<command name="create transaction" code="Moolcrtx" …>` | `<command name="create txn" code="Moolcrtx" …>` |
| `<result type="transaction" …>` on `create transaction` | `<result type="txn" …>` |
| `<result type="transaction" …>` on `pay` | `<result type="txn" …>` |

The four-char code (`Txn `), the cocoa class (`Moolah.ScriptableTransaction`),
the cocoa key (`scriptableTransactions` on profile's element), the
cocoa command class (`Moolah.CreateTransactionCommand`), and every Swift
file under `Automation/AppleScript/` stay untouched. Only the AppleScript-
visible terms change.

### Why `txn`

- Short, unambiguous, and obviously the abbreviation of `transaction` —
  scripters reading existing internal automation will recognise it
  immediately.
- Not reserved anywhere in AppleScript's standard suites or in System
  Events' command set. Verified by the diagnostic agent's probe.
- Other candidates considered and rejected:
  - `entry` — generic; collides with vague mental model around
    dictionary entries and could read awkwardly in `whose` clauses.
  - `payment` — semantically wrong; income transactions are not
    payments.
  - `record` — generic AppleScript value-type term; would confuse
    scripters expecting a dictionary record.
  - `ledger entry` — two-word term reintroduces multi-word-class
    fragility.
  - Keep `transaction` and add a synonym — leaves a known-broken
    term in the public dictionary as a footgun; user prefers a clean
    rename.

### Why the Plural `txns` (Not `transactions`)

The plural form is what AppleScript exposes in `every txns` (parser
internally maps `every X` to the class's `plural=`). Keeping the plural
as `transactions` would defeat the purpose — `every transactions of
profile "X"` would still trip the parser's reserved-word lookup on the
stem. `txns` is the natural plural of the new singular and is not
reserved.

## Compatibility Notes

The user has explicitly waived AppleScript back-compat for human-typed
scripts as part of fixing this issue. Concretely:

- **Existing AppleScripts** that mention `transaction` or
  `transactions` by name must update to `txn` / `txns`. The
  `automate-app` skill doc is the largest consumer; its examples are
  updated in the same commit as the sdef change.
- **Compiled `.scpt` files** that store the class as a four-char code
  (`'Txn '`) continue to resolve correctly — the code is unchanged.
- **The Cocoa Scripting bridge** is untouched: `ScriptableTransaction`,
  `transactionType` `@objc` property, `CreateTransactionCommand`, and
  every other Swift handler keep their names. Only the human-readable
  AppleScript term changes; nothing in Swift moves.

## Verification

1. `just build-mac` and launch the app.
2. Run the previously-failing repros from the issue with the new term:
   - `get id of every txn of profile "X"` → returns a list.
   - `delete txn id "<uuid>" of profile "X"` → succeeds (row vanishes
     from the UI on the next tick).
   - `every txn of profile "X" whose id is "<uuid>"` → returns a list
     of one.
3. Negative-control: the old form still errors (confirming we didn't
   somehow silently keep the broken term):
   - `every transaction of profile "X"` → `-2741`.
4. Regression: previously-working forms keep working with the new
   terms:
   - `count txns of profile "X"` → returns the same integer as
     `count transactions of profile "X"` would have prior to the
     rename.
   - `get {payee, amount} of every txn of profile "X"` → list of pairs.
5. Verify `create txn` works:
   - `create txn in profile "X" with payee "Coffee" amount -5.0 account "Checking"`
     → returns a txn reference.

The sdef is bundled at build time and read by Cocoa Scripting at
runtime; there is no Swift compile-time check for AppleScript term
names. Verification is via the live app and the `moolah-tell` helper.

## Implementation Surface

| File | Change |
|---|---|
| `Automation/AppleScript/Moolah.sdef` | Rename five terminology entries listed in the table above. ~5 single-line edits. |
| `.claude/skills/automate-app/SKILL.md` | Replace the existing shadow caveat with a short note documenting the rename and the four-char-code stability. Update all example commands using `transaction` / `transactions` to `txn` / `txns`. |
| `Automation/AppleScript/Commands/ResetImportCommand.swift` (doc comment only) | The stale shadow-justification comment can be dropped — but the command itself stays useful as a bulk-clear primitive on synced accounts. |

No CloudKit schema change, no GRDB schema change, no `project.yml`
change, no test file change (no unit tests exist for the sdef;
verification is manual against the live app per existing project
pattern).

## Out of Scope

- The previous draft's `transaction type` → `type` property rename.
  Defensible standalone cleanup (matches `leg.type`) but not part of
  #923's actual fix. A separate PR can address it later if anyone wants
  the symmetry.
- No new commands. No new properties. No four-char-code changes.
- No Swift refactor.

## Open Questions

None. User has confirmed `txn` and approved a full rename over the
synonym approach.

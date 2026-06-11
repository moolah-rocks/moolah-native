# Sync deletion durability (#1090) + safe bloated-state recovery

Status: **proposal** (design only — two sequenced designs). Design 1 shipped as
PR #1096 (`fix/deletion-journal`, OPEN). Design 2 implementation is BLOCKED on
PR-B's replay; this revision (2026-06-11) reconciles against PR-A as-built and
applies the adversary's CHANGES-NEEDED (the CRITICAL refetch-resurrection fix +
the byte-size-only gate + the attempt-ceiling reset).
Closes the two deferred items: the (b) empty-shell resurrection class, and the
dropped "safe reset" recovery — **no more deferrals**.

**Sequencing:** Design 1 is a prerequisite for Design 2. Build Design 1 as a
**general deletion journal** (not profile-only), because Design 2's delete-safety
needs every unconfirmed deletion to survive a reset — see §Design 2 / C-2.

---

## Reconciliation against PR-A (#1096) as-built (2026-06-11)

Design 1's journal shipped as **PR #1096 `fix/deletion-journal` (OPEN, not yet
merged)**. Reconciled against it; the design is substantively consistent, with
these as-built refinements folded in:

- **`@profile-data` sentinel (Option B).** Per-profile DATA-zone entries store a
  sentinel `zone_name = "@profile-data"`, not the real `profile-<uuid>`; the real
  zone is resolved **at replay** from the owning DB's `profileId`
  (`DeletionJournal.dataZoneName(for:)`). Index-zone entries (`ProfileRow`) store
  the real `profile-index`. So the §Start-time-replay pseudocode below is
  schematic — PR-B's replay resolves the sentinel per-DB. (Recovery just *invokes*
  PR-B's replay; this doesn't change the recovery logic.)
- **`DeletionJournal.clearAll(in:)` on teardown.** PR-A wipes the journal in the
  same write that wipes data on sign-out / account-switch / zone-purge (so stale
  cross-account intents don't replay). This **strengthens** Design 2's safety gate
  and is the reason for the explicit *recovery-never-touches-the-journal* invariant
  (see §Design 2 / Safety gate).
- **Schema:** PR-A's table is `STRICT, WITHOUT ROWID` with PK `(zone_name,
  record_name)`, `queued_at REAL`, plus a `deletion_journal_by_queued_at` index
  backing the replay's `ORDER BY queued_at`. (Refines this doc's `STRICT`+PK.)
- **Journaled set = 9 data types + Profile:** Transaction, TransactionLeg,
  InvestmentValue, TransferSuggestion, Category, AccountGroup, EarmarkBudgetItem,
  ImportRule, CSVImportProfile + `ProfileRow`. **Account and Earmark are
  intentionally NOT journaled** — their user-deletion is a SOFT delete
  (`is_hidden = true`), i.e. a *save* covered by `needs_push`, not a CKRecord
  deletion. (Only the hard-deleted EarmarkBudgetItem from a zero-amount setBudget
  is journaled.) This resolves the doc's loose "…accounts, earmarks…" wording.
- **Open Q1 (shared instruments) — RESOLVED.** `InstrumentRow` is NOT journaled,
  correctly: `GRDBInstrumentRegistryRepository.remove(id:)` fires `onRecordDeleted`,
  but the shared registry's delete hook is **unwired (default no-op)** — only the
  `ProfileRow` profile-index hook is wired. Instrument deletions are never
  propagated to CloudKit, so there is no pending instrument deletion to lose →
  C-2 unaffected. (Separate, pre-existing, out-of-scope: a locally-removed
  instrument resurrects on ANY full refetch — recovery's included — because its
  deletion isn't synced. Worth its own issue, not a journal/recovery gap.)

---

## Background: why deletions are not durable today

Two mechanisms, confirmed in code:

- **A save's intent is durable** — `needs_push=1` on the local row persists in
  GRDB across engine-down and sync-state reset, and `queueAllExistingRecords`
  re-derives it (`collectGRDBRecordIDs(source: .all)` enumerates every row).
- **A delete's intent is NOT durable** — deleting a row removes it from GRDB and
  fires `queueDeletion` → `syncEngine?.state.add(.deleteRecord)`
  (`+QueueChanges.swift:30-41`). That `syncEngine?` **no-ops when the engine is
  nil** (delete-while-down), and the pending change is discarded by a sync-state
  reset. There is **no `needs_push` equivalent for deletions** — nothing to
  re-derive from, because the row is gone.

So a deletion is lost whenever the engine is down at delete time, or the state is
reset. Symptoms: profile-index `ProfileRow` deletion lost → **empty-shell
resurrection** (the data zone is deleted directly via
`privateCloudDatabase.deleteRecordZone`, durable, but the index record lingers);
data-record deletion lost → that record **resurrects** on refetch.

The fix is the symmetric counterpart to `needs_push`: a **durable deletion
journal** of "(zone, record) needs delete-propagation", replayed on start and
cleared on confirmation.

---

## Design 1 — #1090 durable deletion journal (replaces "profile tombstone")

A small persisted journal of deletion intents, written at delete time, replayed
on engine start, cleared on confirmation. Profile-index `ProfileRow` deletion is
the **first consumer** (fixes the empty shells), but the journal is **general** so
Design 2 can replay *all* deletions.

### Storage (must survive a sync-state reset → NOT in engine state)

A GRDB table, one per database that can originate deletions:

- **Profile-index DB** (`ProfileContainerManager.profileIndexDatabase`):
  journals deletions of profile-index-zone records — `ProfileRow`s and shared
  `InstrumentRecord`s. Survives per-profile DB teardown, so a deleted profile's
  index-record deletion outlives its data DB.
- **Each per-profile DB:** journals deletions of that profile's data-zone records
  (transactions, legs, accounts, earmarks, …). If the profile itself is later
  deleted, this table dies with the DB — which is correct: the whole data zone is
  deleted directly, and the profile's index deletion lives in the index journal.

Schema (per DB):

```
CREATE TABLE deletion_journal (
  zone_name    TEXT NOT NULL,   -- CKRecordZone.ID zoneName
  record_name  TEXT NOT NULL,   -- CKRecord.ID recordName (prefixed form)
  record_type  TEXT NOT NULL,   -- for logging / dispatch
  queued_at    DOUBLE NOT NULL, -- for observability / ordering
  PRIMARY KEY (zone_name, record_name)
) STRICT;
```

Keyed by `(zone_name, record_name)` so re-deleting is idempotent and the entry
maps 1:1 to a `CKRecord.ID`.

### Delete-time write (capture POSITIVE intent, atomically)

The journal `INSERT` **must run inside the same `database.write` that deletes the
local row** — the per-repository delete method, **not** the post-commit sync hook
(D1-a). Today's hook is the wrong seam: `attachSyncHooks(onRecordDeleted:)` fires
`Task { @MainActor in queueDeletion(...) }` (`+ProfileIndexHooks.swift:21-25`) —
**post-commit, async, on a different actor**, outside the repo's write. A crash
between the row-delete commit and that async write loses the intent →
resurrection. So the journal write is a **per-repository-delete-method change**,
co-located with the `deleteOne`/`deleteAll` inside one transaction:

- **Profile deletion:** in the **profile-index repository's** delete of the
  `ProfileRow` (the GRDB `database.write` that removes the row), `INSERT` the
  journal entry for that `ProfileRow`'s `CKRecord.ID` into the index journal — in
  the same transaction. (The index journal lives in the profile-index DB, so it
  outlives the per-profile DB teardown; the direct `deleteCloudKitZone` stays as
  is, but the *journal* write belongs in the index repo's row-delete txn, not in
  `deleteStore`.)
- **Data-record deletion:** every repository delete method that removes a synced
  row (`deleteOne`/`deleteAll` for transactions, legs, accounts, earmarks, …)
  also `INSERT`s the journal entry into that profile's journal **in the same
  `database.write`**.

`queueDeletion` still runs as today (the fast path when the engine is up, fired
post-commit by the hook); the **in-transaction journal write** is the atomic
durability backstop. Do **not** route the journal write through the hook.

### Clear-on-recreate (D1-b) — symmetric journal, in the same write as the create

A stale journal entry is **NOT harmless** for a delete→recreate-same-id sequence:
delete X (journal entry written) → reset / engine-down before propagate+clear →
X **re-created locally with the same `CKRecord.ID`** (undo / restore / UUID reuse)
→ next start: `queueAllExistingRecords` queues `.saveRecord(X)` **and** the journal
replay queues `.deleteRecord(X)` → the replay **deletes the live re-created X** =
data loss.

**Fix:** make the journal symmetric. On every record **insert/upsert**, atomically
`DELETE FROM deletion_journal WHERE (zone_name, record_name) = …` **in the same
`database.write` that creates the row**, so a re-created record clears its own
stale deletion intent before any replay can fire. (Same transactional discipline
as the delete-side write — one place per repository create/upsert method.)

### Start-time replay (the only safe re-issue path)

In `completeStart`, after the engine is installed (and alongside the existing
start purges), **replay** every journal entry as a `.deleteRecord`:

```
for (db, profileId?) in [indexDB] + liveProfileDBs:
  for entry in db.deletionJournal:           # DeletionJournal.allEntries (ORDER BY queued_at)
    # PR-A stores "@profile-data" as the sentinel zone_name for per-profile data
    # entries; resolve it to the real profile-<id> zone from the owning DB.
    let realZone = entry.zone_name == "@profile-data"
                     ? "profile-\(profileId)" : entry.zone_name
    syncEngine.state.add(pendingRecordZoneChanges:
      [.deleteRecord(CKRecord.ID(recordName: entry.record_name,
                                 zoneID: zone(realZone)))])
```

This makes deletion durable regardless of engine timing or a sync-state reset.
(PR-B owns this replay; the sentinel resolution above matches PR-A's
`DeletionJournal.dataZoneName(for:)`.)

### Clearing the journal (idempotent; imperfect clearing is still safe)

CKSyncEngine **does not report successful deletes** (`SentRecordZoneChanges`
exposes only `savedRecords` / `failedRecordSaves` / `failedRecordDeletes`,
`+RecordChanges.swift:210-244`). So clear via the two observable signals:

1. **`.deleteRecord` left `pendingRecordZoneChanges` after a send** → it was sent
   successfully → clear that journal entry.
2. **`failedRecordDeletes` with `.unknownItem`** → the server already lacks the
   record → clear (it's gone either way).

Because replay is **idempotent** (deleting an already-gone record is a harmless
`.unknownItem`), imperfect clearing of a *still-deleted* record only costs a
redundant `.deleteRecord` on the next start — never data loss; so this clearing is
a tidiness optimization. **The one case where a stale entry IS harmful — a record
re-created with the same id — is handled separately and authoritatively by the
clear-on-recreate write (D1-b) above, not by this lazy clearing.**

### HARD safety rule

**Replay ONLY from a journal entry (positive recorded intent). NEVER infer a
server deletion from "record absent locally".** Absence is ambiguous — a record
not present locally may be a peer's brand-new record this device hasn't fetched,
not one this device deleted. Inferring deletions from absence would delete other
devices' new data. The journal exists precisely to record positive intent so we
never infer.

### Tests (Design 1)

- **Delete-while-engine-down → durable:** with `syncEngine == nil`, delete a
  profile → assert a journal row exists; start the engine → assert the
  `ProfileRow` `.deleteRecord` is queued → simulate ack/leaves-pending → journal
  cleared; the profile does **not** resurrect on a subsequent fetch (no shell).
- **Data-record delete-while-down → durable:** same shape for a transaction.
- **Sync-state reset → durable:** journal survives deleting the syncstate file;
  next start replays the deletions.
- **Idempotent replay:** replaying an already-deleted record yields `.unknownItem`
  and clears, no error.
- **Absence is never a delete:** a locally-absent record with **no** journal entry
  is **never** queued for deletion (regression-lock on the hard rule).
- **Atomic insert (D1-a):** the journal `INSERT` happens **inside** the repo's
  delete `database.write` — assert that after the delete transaction commits the
  journal row is already present (no dependency on the async hook), and that a
  delete with the engine nil still journals. (Drives the in-transaction seam, not
  the post-commit hook.)
- **Re-create safety (D1-b):** delete X (journal written) → re-create X with the
  **same `CKRecord.ID`** → on the create write, assert the journal entry is gone →
  start/replay → assert X is **NOT** deleted (live re-created record survives).
  Direct data-loss regression-lock.

---

## Design 2 — safe already-bloated-state recovery (the reset, made data-safe)

With Design 1's journal making deletions durable, a size-gated reset becomes
**data-safe** and an already-wedged install **self-heals on launch** — no manual
syncstate deletion.

### Trigger

In `prepareEngine`, **before** `CKSyncEngine(configuration:)`, gate on the
persisted state's **byte size** (`Data.count` — already in hand at the file read,
`SyncCoordinator+Lifecycle.swift:~117`). Above a high `BLOAT_BYTES` threshold (a
healthy state is KB–low-MB; the wedge was 42.5 MB, ≈280 B/change), the state is
pathological and would stall init → **recover**: construct the engine with
`stateSerialization: nil` (empty state, instant init). Log loudly.

**The gate is byte-size, NOT pending-count.** `CKSyncEngineStateSerialization` is
opaque `NSSecureCoding`; its `Codable` form is `{"data": base64(opaque bplist)}`,
so the cheap `JSONDecode` in `prepareEngine` succeeds *precisely because it does
not parse the pending list* — and therefore can't count it. Only
`CKSyncEngine.init` deserializes the pending changes (the very stall we're
avoiding), so a pre-init count is unimplementable. File size is the only signal
available pre-init, and 42.5 MB vs KB–low-MB is a clean separation.

> This is the same size-gate previously rejected *only because the reset lost
> data*. Designs 1 + the save-complete re-queue remove that objection; the gate
> itself was never the problem.

### Safety gate — fires, must-not-fire, and the attempt ceiling

**Fires only when ALL hold:** `Data.count > BLOAT_BYTES`; iCloud account
**available** (never during sign-out / restricted / no-account); and
`recoveryAttemptCount < CEILING`.

**MUST NOT fire** on a healthy/small state (else every launch re-fetches +
re-uploads the whole account — the dominant over-eager-gate risk), during a
zone-purge / `encryptedDataReset` (those own their reset), or mid sign-out.

**Attempt ceiling WITH a reset rule.** `recoveryAttemptCount` caps consecutive
recoveries so a state that re-bloats *every* launch (real data exceeds the gate, or
a deeper bug) degrades to warning-only instead of looping. **Crucially, any launch
that observes a healthy (below-threshold) state resets the count to 0** — that
distinguishes "recovery worked, re-arm for a future bloat months later" from
"keeps re-tripping on consecutive launches." Without the reset the ceiling becomes
a permanent cap and a legitimately-re-bloated install months later could never
self-heal.

**Recovery never touches the journal (delete-safety invariant).** Recovery resets
ONLY the engine state (`stateSerialization: nil`). It MUST NOT call
`DeletionJournal.clearAll` or otherwise wipe the GRDB journal — the journal is
exactly what makes the reset delete-safe. (`clearAll` is reserved for genuine
local data wipes — sign-out / account-switch / zone-purge — which is why recovery
must also not be conflated with those teardown paths.)

### Save-completeness → closes CRITICAL-1

The reset's re-queue **must** use the `isFirstLaunch = true` →
`queueAllExistingRecordsForAllZones` path. Verified save-complete:
`queueAllExistingRecords` → `collectGRDBRecordIDs(source: .all)` enumerates
**every** local row, independent of `encoded_system_fields` / `needs_push`. So it
captures edited-after-sync rows (`needs_push=1`, blob ≠ NULL) that the
`encoded_system_fields IS NULL` backfill (`unsyncedRowIdsSync`) misses — the exact
class the adversary's **C-1** flagged. Do **NOT** use
`queueUnsyncedRecordsForAllProfiles` (it would re-drop the migration's
create→update edits and is also gated by `hasCompletedBackfillScan`).

> Note: `queueAllExistingRecordsForAllZones` re-uploads *every* local record
> (heavy but correct; one-time). Under the #1085 `modificationDate` apply-gate and
> CKSyncEngine's `serverRecordChanged` conflict path, re-uploads converge — an
> older server echo can't clobber, and a newer server record is fetched (tokens
> were reset → full refetch) and conflict-resolved.

### Delete-safety → closes CRITICAL-2 (and the gating requirement)

A reset discards the entire pending set, **including pending `.deleteRecord`s**.
Save re-derivation does not cover deletes (the rows are gone). **Design 1's
journal replay is what makes the reset delete-safe** — on the post-reset start,
every unconfirmed deletion is replayed from the journal, so nothing resurrects.

**This is the gating requirement, stated plainly:** Design 2 is delete-safe **only
if Design 1's journal is GENERAL _and_ ATOMIC (in-transaction insert, D1-a) _and_
RE-CREATE-SAFE (clear-on-insert, D1-b).** Each is load-bearing:
- **General** — a profile-only tombstone would let a reset resurrect a
  locally-deleted *transaction/account/etc.* whose deletion hadn't uploaded.
- **Atomic (D1-a)** — a journal written by the post-commit async hook is lost to a
  crash in the commit→hook window, so that deletion still resurrects.
- **Re-create-safe (D1-b)** — without clear-on-insert, a delete→recreate-same-id
  sequence replays a `.deleteRecord` over the live re-created record (resurrect-
  then-kill).

With all three, C-2 is genuinely closed **for a normal, token-preserving replay.**
They are **NOT sufficient under recovery** — see the next section.

### Delete-safety under the token-less refetch — the recovery-only hazard (CRITICAL)

Recovery's `nil`-reset also discards the change tokens and forces a **full
re-fetch**, which re-delivers any record deleted locally whose `.deleteRecord`
never propagated (it was stuck in the bloated pending state, so the **server copy
still exists**). That re-delivery collides with the journal:

1. Pre-recovery: delete X locally → tombstone written, but the `.deleteRecord`
   never reached the server → **X still on the server**.
2. Recovery: `stateSerialization: nil` → tokens gone → the full re-fetch
   **re-delivers X**.
3. PR-A's apply path upserts X back into GRDB **and clears X's tombstone** — the
   D1-b "a peer re-created this id" clear (verified in
   `GRDBCategoryRepository+Sync.swift`, `GRDBInvestmentRepository+Sync.swift`).
4. **Race — both orderings lose:**
   - *fetch before replay*: the re-fetch clears the tombstone before replay reads
     it → X is permanently resurrected locally AND re-propagated → the user's
     delete is **silently lost**.
   - *replay before fetch*: replay deletes server-X, but the re-fetch re-inserts
     local-X and (D1-b) clears the tombstone → a later `.deleteRecord` upload
     won't remove the already-applied local row → local/server divergence with no
     tombstone to recover from.

   Send-time delete-wins does **NOT** fix this — it only reconciles the *server*
   copy, never the re-inserted *local* row or the cleared tombstone. (This is the
   error in an earlier draft's "disjoint sets + send-time delete-wins" claim.)

**Fix — recovery-scoped tombstone shield.** At recovery start, snapshot the union
of all tombstone ids (index DB + every live profile DB) into an in-memory
`recoveringDeletions` set. For the duration of the recovery session, the apply
path must, for any incoming saved record whose `CKRecord.ID` is in that snapshot:
**skip the upsert AND skip the D1-b tombstone clear** — let the replayed
`.deleteRecord` win on both the local row and the server copy. The snapshot is
consulted only during the post-recovery re-fetch+replay and released once recovery
settles (the normal PR-B clear-on-confirm then retires each tombstone as its
`.deleteRecord` is acked). It shields exactly the deleted-but-un-propagated
records — a genuine peer re-create of an id NOT in the snapshot still upserts +
clears normally.

This hazard is **recovery-specific**: a normal PR-B replay preserves the tokens,
so the server never re-delivers X and it cannot arise. Only the `nil`-reset's
token loss + full re-fetch re-materialises deleted records.

### Tokens → one-time full refetch (cost stated)

A `nil` state loses the server change tokens → the next fetch re-downloads all
zones. Idempotent and safe under the #1085 gate (older echoes rejected). One-time
cost, acceptable for an emergency recovery. The save re-queue + journal replay run
concurrently with this refetch; convergence holds via the conflict path **and the
recovery-scoped tombstone shield above** (which is what stops the refetch
resurrecting a deleted-but-un-propagated record).

### Self-heal flow (the end-to-end win)

On first launch of the fixed build against an already-wedged 42.5 MB state:
1. `prepareEngine` size-gates → builds the engine with `nil` state → **init
   completes instantly**, `completeStart` runs.
2. `queueAllExistingRecordsForAllZones` re-queues every local record
   (save-complete); Design 1 replays every journaled deletion (delete-safe);
   the §2b reconciliation drops any dead-profile pending; the head is clear.
3. A one-time full refetch re-establishes the server view **under the
   recovery-scoped tombstone shield** (so a re-delivered deleted-but-un-propagated
   record is not re-inserted / its tombstone not cleared); uploads + deletes
   propagate; the migration unblocks. **No manual syncstate deletion.**

### Re-derivation against the adversary's C-1 / C-2

- **C-1 (save-completeness) — CLOSED.** `queueAllExistingRecordsForAllZones`
  enumerates every local row (`collectGRDBRecordIDs(.all)`), so `needs_push=1`
  edited rows are re-queued. The data-loss bug was the prior `isFirstLaunch=false`
  optimisation, which is removed.
- **C-2 (delete resurrection) — CLOSED by Design 1 + the recovery-scoped
  tombstone shield**, provided the journal is **general + atomic (D1-a) +
  re-create-safe (D1-b)** AND recovery snapshots the tombstone id-set and skips
  upsert+D1-b-clear for those ids during the post-reset refetch (the CRITICAL
  fix above). The token-less refetch re-downloads a server copy of a
  deleted-but-un-propagated record, but the shield stops it being re-inserted /
  its tombstone cleared, so the replayed `.deleteRecord` wins on both local and
  server; meanwhile a genuine peer re-create-same-id (not in the snapshot) is
  *not* killed (D1-b) and no deletion is lost to the commit→hook window (D1-a).

### Interaction with off-main init (Layer 1 primary, from the wedge doc)

Off-main init remains the **primary, zero-data-cost** path for a *non*-pathological
state. Design 2's reset is the **recovery valve** for a state so bloated that even
off-main init can't complete in acceptable time. Both coexist: try off-main first;
size-gate-reset only when the state is pathological. (If the off-main spike shows
init always completes off-main regardless of size, Design 2 becomes a pure
belt-and-braces valve — still worth having now that it's data-safe.)

### Tests (Design 2)

- **Save-complete reset:** seed a profile with an edited-after-sync row
  (`needs_push=1`, blob ≠ NULL) + a never-synced row; trigger the size-gate reset;
  assert **both** are re-queued (the edited row is NOT dropped). Direct C-1
  regression-lock.
- **Delete-safe reset:** seed a journaled deletion (data record + profile);
  trigger the reset; assert the deletions are replayed and the records do **not**
  resurrect after a simulated refetch. Direct C-2 regression-lock.
- **Refetch-resurrection (CRITICAL regression-lock):** delete X locally with the
  `.deleteRecord` UN-propagated (X still on the server) → trigger recovery →
  simulate the full re-fetch re-delivering X, in **BOTH** orderings (refetch
  before replay, and replay before refetch) → assert X is NOT resurrected
  **locally OR on the server** and the tombstone is not prematurely cleared. This
  fails without the recovery-scoped tombstone shield.
- **Shield is scoped, not global:** a peer re-create of an id NOT in the recovery
  snapshot still upserts + clears its (absent) tombstone normally — the shield
  doesn't suppress legitimate incoming records.
- **Size-gate:** oversized state file → engine built with `nil` state +
  `isFirstLaunch=true`; normal file → state passed through unchanged.
- **Attempt-ceiling reset:** a recovery followed by a healthy (below-threshold)
  launch resets `recoveryAttemptCount` to 0 (re-armable); N consecutive
  above-threshold launches stop firing (warning-only).
- **End-to-end self-heal:** wedged-state fixture → launch → init completes, queue
  drains, no manual intervention.

---

## Open questions for the adversary

**Resolved by the PR-A reconciliation (see top section):**
- ~~Q1 Journal generality / shared instruments~~ — RESOLVED: PR-A journals the 9
  hard-deleted synced data types + Profile; Account/Earmark are soft-deletes
  (saves); instrument deletion is unsynced (no-op hook) so correctly unjournaled.
- ~~Q3 Per-profile journal lifetime~~ — RESOLVED: PR-A uses per-DB journals with
  the `@profile-data` sentinel + `clearAll` on teardown.

**Still open:**
1. **Clear signal (PR-B).** Is "delete left `pendingRecordZoneChanges` after a
   send" a reliable success signal (CKSyncEngine surfaces no success list), with
   `.unknownItem` as the secondary clear? Acceptable that imperfect clearing only
   costs an idempotent redundant delete next start?
2. **Size-gate threshold & metric (#12).** With the reset now data-safe, a
   false-positive reset costs only a one-time refetch (no data loss). What
   `BLOAT_BYTES` cleanly separates pathological (42.5 MB) from a legitimate
   big-import state? Ship observe-only first (log `Data.count` distribution),
   calibrate, then enable.
3. **Replay volume (PR-B).** A huge journal (mass deletion before a wedge) replays
   many `.deleteRecord`s — fine (small, idempotent), but worth a cap / batching
   note?
4. **Recovery-scoped tombstone shield lifetime (#12, NEW from the Critical).** How
   long must the `recoveringDeletions` snapshot suppress upsert + D1-b-clear — for
   the whole first post-recovery fetch+replay cycle, or until each tombstone's
   `.deleteRecord` is confirmed-acked? Where does the apply path read the snapshot
   (it must be visible to every per-repo `applyRemoteChangesSync`)?
5. **Recovery vs teardown `clearAll` (#12, NEW).** Confirm the recovery path can
   provably never be conflated with a sign-out / account-switch / zone-purge
   teardown (which `clearAll`s the journal) — recovery must reset engine state
   only, never wipe the journal.
6. **Instrument-deletion-not-syncing** — should the pre-existing "a removed
   instrument resurrects on any full refetch" behaviour get its own issue
   (orthogonal to #1090/#12)?

---

## Citations

- Durable-save asymmetry: `+QueueChanges.swift:30-41` (`queueDeletion` →
  `syncEngine?.state.add`), `ProfileDataSyncHandler+QueueAndDelete.swift:12`
  (`queueAllExistingRecords` → `collectGRDBRecordIDs(source: .all)`),
  `GRDBTransactionLegRepository.swift:189-196` (`unsyncedRowIdsSync` =
  `encoded_system_fields IS NULL`).
- Direct durable data-zone delete vs lossy index-record delete:
  `ProfileContainerManager.swift:156` (`deleteCloudKitZone` →
  `deleteRecordZone(withID:)`), `SyncCoordinator+ProfileIndexHooks.swift:23`
  (index `queueDeletion`).
- Sent-change ack surfaces no successful deletes:
  `SyncCoordinator+RecordChanges.swift:210-244`.
- Reset / size-gate seam: `SyncCoordinator+Lifecycle.swift:113-129`
  (`prepareEngine`), `:167-180` (`isFirstLaunch` → `queueAllExistingRecordsForAllZones`).
- C-1/C-2 origin + #1085 gate: `GRDBTransactionRepository+Update.swift:55-61`
  (blob preserved, only `needs_push` set); the merged #1085 `modificationDate`
  apply-gate.

# Upload-queue wedge — root cause & fix design

Status: **proposal** (design only)
Worktree: `.claude/worktrees/fix-upload-queue-wedge` (off `main`, includes #1085).
Symptom (Development container): `…/Application Support/Development/Moolah-v2-sync.syncstate`
is **42.5 MB, frozen since 10:26**, ~152 k pending changes, **nothing uploads**;
the crypto migration is blocked. Not CloudKit rate-limiting.

---

## 1. Root cause — TWO compounding problems (confirmed against code + the live artifact)

### Problem 1 (primary): startup never reaches a running engine — most likely MainActor starvation, NOT init-on-main

**Symptom:** the log shows "CloudKit available — starting sync coordinator" but
**never** "Started unified sync coordinator" (`+Lifecycle.swift:145`, the first
line of the back-on-MainActor `completeStart`). So `completeStart` /
zone-setup / `sendChanges` never run, and nothing can drain.

**Revised diagnosis (corrected after adversary review — see §9).** My first
draft asserted `CKSyncEngine.init` blocks the *main* thread internally, on the
strength of a single process `sample`. That contradicts the code and is most
likely wrong:

- `SyncCoordinator` is `@MainActor` (`SyncCoordinator.swift:20`); `start()`
  (`:80`) spawns `Task { await Self.prepareEngine(...) }`. `prepareEngine`
  (`:113`) is `nonisolated async`, and it calls `CKSyncEngine(configuration:)`
  **synchronously** from that nonisolated context. For that to compile,
  `CKSyncEngine.init` is **not** `@MainActor`-isolated — so it runs on the
  cooperative pool, **off** the main thread. Issue #565 verified exactly this
  (`Thread.isMainThread == false`, distinct OS TID). The codebase deliberately
  put init here for this reason (`:86-91`, `:104-112`).
- The far more code-consistent reading of the `sample`: the **main thread is
  pinned by the concurrent Insights/Analysis crypto-conversion storm**
  (~14 k conversions / 6 min in the open profiles), while
  `CKSyncEngine.init` grinds **off-main** on the 31 MB blob. With the
  MainActor saturated, the continuation that resumes `prepareEngine` and runs
  the `@MainActor` `completeStart` **cannot get scheduled** — so "Started…"
  never logs even though init may have finished (or is finishing) off-main.

So the blocker is most plausibly **MainActor starvation delaying `completeStart`**
(and/or a genuinely slow but completing off-main 31 MB deserialization) — **not**
init executing on the main thread. This flips the fix: the lever is to **free
the MainActor / guarantee off-main init**, not to shrink the state by a
data-losing reset. The decisive question is empirical (the spike in §2 Layer 1).

> The earlier "only lever is to reduce what we hand init" framing — and the
> reset built on it — is **withdrawn** as the primary fix; see §2 Layer 1 and
> §9. The existing purges (`purgeStaleBareUUIDPendingChanges`, `:156`;
> `purgeLegacyInstrumentPendingChanges`, `:165`) do run only after the engine
> exists, but if init completes off-main with the MainActor free, that is no
> longer a problem.

### Problem 2 (steady-state): head-of-line wedge — stale `.saveRecord`s never removed

Independently, even when sends *do* run, the front ~400 pending are stale
`.saveRecord`s for prefixed records **deleted locally** (left from a deleted
profile). Per send pass (`nextRecordZoneChangeBatchOnMain`, `+Delegate.swift:88`):

1. `dedupedPendingChanges` (`:194`) keeps them (their zone is **not** in
   `pendingZoneCreation`; a deleted zone isn't pending-creation).
2. `selectBatchKind`→`.profileData`; `filterChanges(...).prefix(400)`
   (`+BatchKind.swift:50`) takes them **in stable queue order** — the same dead
   head every cycle.
3. `buildRecordsToSave`→`appendProfileDataRecords` (`:271`): `handlerForProfileZone`
   does **not** throw for a deleted profile — `containerManager.database(for:)`
   (`ProfileContainerManager.swift:68`) re-opens `ProfileDatabase.open(at:
   data.sqlite)`, which **re-creates a fresh empty migrated DB**. The batch
   lookup finds no rows → every id is a miss → `built = 0`.
4. `handleMissingRecordsToSave` (`:350`) tail-queues `.deleteRecord`s via
   `state.add(...)` — appended **beyond** the `prefix(400)` window — and the
   stale `.saveRecord`s are **never removed**. `newMissingDeleteIDs`
   (`+QueueChanges.swift:57`) even documents (`:51-56`) that it deliberately
   leaves the save, assuming "CKSyncEngine resolves the order itself." **It does
   not.** Both coexist; the head is re-selected forever. `built=0`, `deletes=0`
   in-batch → `nextBatch` returns nil. Total upload starvation.

Observed signature (already emitted by `logBatchOutcome`, `+Delegate.swift:178`):
`pending=152298 deduped=152298 batch=400 saves=0/400 deletes=0` + the `.error`
"expected 400 saves but built 0 records — records remain pending".

> Note on the verb `synchronize`: it is the crypto-import refetch, **not**
> `CKSyncEngine.sendChanges`. `sendChanges` fires only via the startup
> zone-ready path (`+Lifecycle.swift:211-214`, `if hasPendingChanges`) or
> CKSyncEngine's discretionary `automaticallySync`. With Problem 1 blocking
> startup, neither runs — so the existing state cannot drain at all today.

### The persisted state is opaque (decisive for the fix shape)

I inspected the actual frozen artifact read-only. `CKSyncEngine.State.Serialization`'s
Codable form is `{"data": "<base64>"}`; the base64 decodes to a **`bplist00`
binary plist of 31.7 MB** — CloudKit's internal, undocumented keyed archive
bundling **both** the server change tokens **and** the 152 k pending changes.
There is **no JSON-level pending-changes array to filter**: surgically dropping
pending changes while preserving tokens would require editing CloudKit's private
binary-plist structure — version-dependent and unsafe (a malformed edit risks
`init` rejecting the state or silently corrupting the tokens). **Token-preserving
surgical slim is therefore rejected** — which matters because it means the only
"slim pre-init" option is a *full* token-losing reset. Combined with the
save-completeness and delete-resurrection failures of a reset (§3, §9), this is a
further reason the primary fix is **off-main init**, not slimming.

---

## 2. The fix — off-main startup (primary) + steady-state purges (Layer 2)

### Which layer fixes which regime (read this first)

| regime | what happens | who fixes it |
|---|---|---|
| **Existing bloated state (the current blocker)** | startup never reaches `completeStart` — MainActor starved by the conversion storm and/or slow off-main 31 MB init | **Layer 1: free the MainActor / guarantee off-main init** (token-preserving). Reset only as a proven last resort |
| **Head-of-line wedge (engine already running)** | `nextBatch` runs but `built=0` on a stale dead head | **Layer 2a** (remove-in-place) + **2c** (delete-time purge) |
| **Healthy-but-stale install (sub-pathological leftover saves)** | engine starts; some stale saves linger | **Layer 2b** (post-init bulk purge) |

### Layer 1 (primary) — make startup complete on the bloated state WITHOUT a reset

The goal is to get `completeStart` to run on the existing 42.5 MB state with
**no token loss and no data loss**. Two complementary levers, both cheap to try;
implementing them *is* the empirical spike that settles §1's diagnosis:

The fix is a single change — **guarantee `CKSyncEngine.init` runs off the main
thread and resumes on the MainActor**: construct the engine in a `Task.detached`
(defensively off-actor regardless of actor-inheritance subtleties), then hop the
finished engine back to the `@MainActor` `SyncCoordinator` for `completeStart`.
The code already intends this (`:86-112`); make it robust and explicit.

**Do NOT pre-emptively build a conversion-storm quiesce.** The Insights/Analysis
crypto-conversion workload (~14 k conversions / 6 min) pegs the MainActor and is
the suspected reason the `completeStart` continuation can't schedule — but
whether it actually blocks `completeStart` is exactly what the spike measures.
The realistic spike condition is **off-main init with the storm present**.

**Decisive empirical test (the spike, owned with the verifier):** on the live
42.5 MB state, with init forced off-main **and the conversion storm present
(realistic condition)**, does `CKSyncEngine.init` **complete** and does
**"Started unified sync coordinator"** log, and the queue drain?
- **If yes** (expected — the storm is likely bursty, so `completeStart`
  schedules once init returns and the burst subsides): Layer 1 is done with the
  off-main change **alone** — tokens preserved, no refetch, no resurrection, no
  save-completeness risk. The two reset criticals (§3) never arise.
- **If `completeStart` is starved** because the storm *continuously* pins the
  MainActor: that is a **separate Analysis-path performance issue** ("conversion
  storm starves the MainActor"), filed and owned **separately** — NOT folded into
  this sync wedge fix. The wedge fix stays scoped to the sync layer.
- **If init genuinely cannot complete off-main** (e.g. OOM / pathological
  deserialization): escalate to the reset *fallback* below (extra safety work +
  owner sign-off).

### Layer 1 fallback (last resort only) — size-gated reset, IFF made data-safe

Only if the spike proves init cannot complete even off-main with a free
MainActor. A reset (`stateSerialization: nil`) makes init trivial but is
**data-losing as designed** — it must NOT ship without both of the following
(see §3 for why each is mandatory):

- **Save-complete re-queue:** use the **`isFirstLaunch = true` →
  `queueAllExistingRecordsForAllZones`** path (re-queues *every* local row, which
  holds the newest version; correct re-upload under the #1085 gate). Do **NOT**
  use `queueUnsyncedRecordsForAllProfiles` — it filters `encoded_system_fields IS
  NULL` and so **misses every record edited after first sync** (blob preserved,
  only `needs_push=1`), silently dropping exactly the migration's
  create→update edits. *(This corrects the prior draft's `isFirstLaunch=false`
  optimisation, which was a data-loss bug — CRITICAL-1.)*
- **Delete-safe replay:** there is **no tombstone table**, so a reset loses every
  pending `.deleteRecord` and the token-less refetch **resurrects user-deleted
  data** (CRITICAL-2). A reset therefore additionally requires a durable
  deletion-intent record (tombstone) that the post-reset path replays as
  `.deleteRecord`s — net-new infrastructure.
- **Size-gate caveat:** a false-positive reset now means **data loss**, not just
  a refetch, so the threshold (if a reset survives at all) must be set far above
  any legitimate state and treated as an emergency valve, not a routine path.

Given the off-main route preserves all data, the recommendation is to **ship
Layer 1 primary and likely drop the reset entirely**; keep the fallback documented
only against the unlikely "init can't complete off-main" spike result.

### Layer 2 — stop the state ever re-bloating (steady-state; lands regardless of Layer 1 outcome)

Adversary-endorsed; closes a real latent data-loss path today (§3 ii). These keep
the pending queue small so the bloated-state regime does not recur.

**2a. Remove the stale `.saveRecord` in `handleMissingRecordsToSave`** (the
verifier's core ask). On a **clean miss** (record genuinely gone locally),
`state.remove(pendingRecordZoneChanges: [.saveRecord(id)])` in addition to
queueing the compensating delete. `state.remove(...)` is an established idiom
(`+Lifecycle.swift:308`, `+LegacyInstrumentDrain.swift:69`). This clears the
head so the queue drains.

**2b. Start-time purge of prefixed-records-gone-locally**, analogous to
`purgeStaleBareUUIDPendingChanges`. After the engine exists, drop pending
`.saveRecord`s whose local row no longer exists. Because a naive scan is up to
152 k per-record DB lookups, scope it: only needed on the non-reset path (the
reset path already starts with an empty pending set), and it can piggyback on the
backfill scan that already walks each profile. Extend the existing purge
function family rather than adding a parallel one where practical.

**2c. Purge a profile's pending changes at delete time** (root prevention). The
true origin is that profile deletion (`evictCachedState`, `+HandlerAccess.swift:79`;
`ProfileContainerManager.deleteStore`, `:115`) tears down the DB/zone but leaves
the profile's queued changes in engine state forever. Add a
`state.remove(pendingRecordZoneChanges:)` of all pending changes for that
profile's zone at the delete path. With 2c the wedge cannot form; 2a is the
general guard; 2b repairs an already-accumulated (sub-pathological) queue.

---

## 3. Safety — never drop a save for a record that still exists / has an unsynced edit

This is the critical invariant. Two distinct hazards:

**(i) The primary (off-main) Layer 1 is inherently data-safe** — it preserves the
state verbatim (tokens + pending), so there is nothing to lose. The safety
analysis below applies to the *reset fallback*, which is why the fallback carries
hard preconditions.

**A reset is NOT save-complete via `queueUnsyncedRecordsForAllProfiles`
(CRITICAL-1, corrected).** That backfill filters `encoded_system_fields IS NULL`
(`unsyncedRowIdsSync`, `GRDBTransactionLegRepository.swift:189-196`), but the
#1081/#1085 update path **preserves the cached blob and only sets
`needs_push=1`** (`GRDBTransactionRepository+Update.swift:55-61`, comment: blob
preserved specifically so the row is *not* re-uploaded as unsynced). So any
record edited after first sync has blob ≠ NULL and is **invisible** to the
backfill → its pending save is dropped on reset → permanent loss of the
create→update edit (the exact migration pattern). The backfill also skips
profiles with `hasCompletedBackfillScan` (`+Backfill.swift:74`; persisted, cleared
only on sign-out) → on an existing install it queues **zero**. Therefore a reset
**must** use the `isFirstLaunch=true` → `queueAllExistingRecordsForAllZones` path,
which enumerates *every* local row (save-complete) regardless of blob/needs_push.

**A reset resurrects deleted data (CRITICAL-2).** No tombstone table exists; a
pending `.deleteRecord` lives only in engine state, and the local row is already
gone, so nothing re-derives it. Reset + token-less refetch re-downloads the
server copy → user-deleted financial data **reappears**. #1085 gates saves, not
deletes. This fails the project's no-data-loss bar, so a reset must replay
deletions from a durable tombstone — net-new infrastructure (§2 fallback).

These two are why the reset is demoted to a last-resort fallback and the off-main
route is primary.

**(ii) Layer-2 (2a/2b) must distinguish "genuinely deleted" from "transiently
missing".** Today the lookup **conflates** them: `recordToSave` /
`buildBatchRecordLookup` return `nil` for *both* "row absent" *and* "GRDB fetch
errored", because `fetchRowOrLog` / `fetchRowsBatch`
(`ProfileDataSyncHandler+RecordLookup.swift:376,312`) swallow errors into
`nil`/`[]`. Removing a save on that conflated `nil` would convert a transient
read error into a queued **server deletion** — a latent data-loss path that
exists *today* (it already queues a delete). **Prerequisite for 2a/2b:** surface
a tri-state from the lookup —

| outcome | classify as | action |
|---|---|---|
| row genuinely absent | **absent** | remove `.saveRecord` (+ queue delete) |
| GRDB fetch threw | **failed** | keep pending, retry — never remove/delete |
| handler build threw (`+Delegate.swift:281`) | **failed** | unchanged: keep pending ("exit-on-unresolved-id" safety, preserved verbatim) |

Only **absent** removes a save. This *strengthens* the send path: a transient
GRDB blip can no longer silently delete a live record server-side.

---

## 4. How the EXISTING 42.5 MB state gets unblocked

**Primary path (off-main, no data loss).** On first launch of the fixed build,
`CKSyncEngine.init` runs off-main (Task.detached) on the 42.5 MB state while the
MainActor is kept free (conversion storm deferred). Init completes, the engine
hops back to the MainActor, **"Started unified sync coordinator" logs**, and
`completeStart` runs: the existing purges + Layer 2a/2b clear the dead head,
`sendChanges` builds > 0, and the queue drains with **tokens and all pending
data preserved**. No refetch, no resurrection. The migration unblocks.

The decisive uncertainty is whether off-main init **completes in acceptable
time** on the 31 MB blob with main free — that is the spike the implementer +
verifier run on the live state (§2 Layer 1). Recovery is automatic on next
launch; no manual tool.

**Fallback path (only if the spike fails).** The size-gated reset (§2 fallback),
which would need the save-complete re-queue (`isFirstLaunch=true` /
`queueAllExistingRecordsForAllZones`) **and** tombstone-based deletion replay
before it is safe to ship. Documented, not recommended.

---

## 5. Production relevance (not a dev-only band-aid)

The trigger here is deleted *test* profiles, but **deleting any real profile with
a large pending queue reproduces it in production**: deletion never purges the
profile's queued changes (Problem 2 / §2c), and a large enough leftover queue
re-bloats the state until startup stalls (Problem 1). Both layers are therefore
scoped to be production-correct: 2c prevents accumulation at the source for all
users; off-main startup (Layer 1) keeps any pathological-state launch from
freezing without sacrificing data.

---

## 6. Tests

- **Problem-2 head-of-line reproduction (load-bearing):** seed engine state with
  N `.saveRecord`s for a profile-data zone whose local rows don't exist; drive
  `nextRecordZoneChangeBatchOnMain` repeatedly. Today: builds 0, saves persist.
  After 2a: stale saves are **removed**, queue drains to the next buildable batch.
- **Clean-miss vs error (safety):** a per-type lookup that **throws** leaves the
  `.saveRecord` pending and queues **no** delete; a clean **absent** row removes
  the save and queues the delete. Locks §3(ii).
- **Handler-throw preserved:** `handlerForProfileZone` throw → records stay
  pending, nothing removed/deleted (regression-lock on `+Delegate.swift:281`).
- **Off-main startup (Layer 1, the decisive spike — live, not a unit test):** on
  the 42.5 MB state with init forced off-main and the conversion storm quiesced,
  confirm `CKSyncEngine.init` completes and **"Started unified sync coordinator"**
  logs (verifier owns this on the live machine). Unit-side: assert `start()`
  constructs the engine off the MainActor and `completeStart` runs even while a
  synthetic MainActor-bound workload is enqueued.
- **Delete-time purge (2c):** delete a profile with queued saves → its pending
  changes are gone from engine state; a surviving profile's are untouched.
- **Start-time purge (2b):** seed pending saves for gone-locally prefixed records
  + live records; assert only the gone ones are removed.
- **Reset fallback (only if the spike fails, and only once built):** after a
  reset, `completeStart` runs `queueAllExistingRecordsForAllZones` (save-complete
  — every local row re-queued, including blob≠NULL/`needs_push=1` edited rows),
  **not** `queueUnsyncedRecordsForAllProfiles`; and queued deletions are replayed
  from the tombstone so deleted records are not resurrected.

---

## 7. Decisions & scope (resolved with the owner)

The spike result — **not** another doc round — gates the design from here.

1. **The spike is the gate.** Does off-main init complete on the live 42.5 MB
   state (storm present) and the queue drain? Yes → design settled (off-main +
   Layer 2), adversary reviews the *implementation*. No → re-engage on the reset
   fallback. Owned by implementer + verifier.
2. **Conversion-storm quiesce — NOT built pre-emptively (resolved).** The spike
   runs with the storm present. Only if the storm *continuously* starves
   `completeStart` do we act, and then "conversion storm starves the MainActor"
   is a **separate Analysis-path performance issue with its own owner**, filed
   separately — **not** part of this sync wedge fix.
3. **Deletion tombstone — OUT of scope (conditional prerequisite, resolved).**
   Not built now. **IF** the off-main spike fails and a reset becomes necessary,
   the durable deletion-intent tombstone replay is a **required prerequisite
   task** (separate PR) before any reset ships, alongside the save-complete
   `queueAllExistingRecordsForAllZones` re-queue and owner sign-off.
4. **2b scope/cost (still open).** Is the start-time purge worth its per-record
   lookups, or are 2a (remove-in-place) + 2c (delete-time purge) sufficient, with
   2b folded into the existing backfill scan only? — for the implementation
   review.

---

## 8. Citations (code in this worktree + the live artifact)

- Startup/init stall: `SyncCoordinator+Lifecycle.swift` — `start():80`,
  `prepareEngine:113` (`CKSyncEngine(configuration):127`), `completeStart:133`
  ("Started…" `:145`), existing purges `:156/:165`, `hasPendingChanges:277`,
  `sendChanges:314`. `SyncCoordinator.swift:20` (`@MainActor`),
  `:54` (`PreparedEngine`), `:87` (`stateFileURL`).
- State persistence/shape: `SyncCoordinator+StatePersistence.swift` (JSON
  encode/decode of `State.Serialization`); live artifact
  `…/Development/Moolah-v2-sync.syncstate` = 42.5 MB `{"data": base64(bplist00,
  31.7 MB)}` (opaque; tokens+pending bundled).
- Head-of-line wedge: `SyncCoordinator+Delegate.swift` —
  `nextRecordZoneChangeBatchOnMain:88`, `appendProfileDataRecords:271`
  (handler-throw early-return `:281`), `handleMissingRecordsToSave:350`,
  `logBatchOutcome:178`. `+BatchKind.swift` `selectBatchKind:29`/`filterChanges:50`.
  `+QueueChanges.swift` `newMissingDeleteIDs:57` (comment `:51-56`).
- Re-derivation from `needs_push`: `SyncCoordinator+Backfill.swift`
  `queueUnsyncedRecordsForAllProfiles:65` (→ `queueUnsyncedRecords()`,
  `encodedSystemFields == nil`), `queueAllExistingRecordsForAllZones:131`.
- Lookup error-swallowing (the conflation): `ProfileDataSyncHandler+RecordLookup.swift`
  `fetchRowsBatch:312`, `fetchRowOrLog:376`.
- Empty-DB re-creation for a deleted profile: `+HandlerAccess.swift:44` →
  `ProfileContainerManager.swift:68` (`database(for:)` → `ProfileDatabase.open`);
  delete path `deleteStore:115`, `evictCachedState:79`.
- `state.remove` precedent: `+Lifecycle.swift:308`,
  `+LegacyInstrumentDrain.swift:69`.
- CRITICAL-1 evidence: `GRDBTransactionLegRepository.swift:189-196`
  (`unsyncedRowIdsSync` = `encoded_system_fields IS NULL`);
  `GRDBTransactionRepository+Update.swift:55-61,105` (blob preserved, only
  `needs_push` set); `+Backfill.swift:74` (`hasCompletedBackfillScan` skip).

---

## 9. Reconciliation with the adversary review (what changed and why)

This revision **withdraws the reset as the primary fix** and pivots to off-main
startup, after the adversary surfaced two data-loss criticals and a likely
misdiagnosis. All three are accepted, verified against the code:

- **CRITICAL-1 (accepted, code-confirmed).** The prior draft claimed a reset is
  save-safe because `queueUnsyncedRecordsForAllProfiles` re-derives unsynced
  records. False: that backfill filters `encoded_system_fields IS NULL`, but the
  update path **preserves the blob and only sets `needs_push=1`**
  (`GRDBTransactionRepository+Update.swift:57-61` says so explicitly), so
  edited-after-sync records are invisible to it and would be dropped — exactly the
  migration's create→update edits. Fix: a reset must use
  `queueAllExistingRecordsForAllZones` (`isFirstLaunch=true`); the prior
  `isFirstLaunch=false` optimisation was a data-loss bug and is removed.
- **CRITICAL-2 (accepted).** No tombstone table exists, so a reset loses pending
  deletes and resurrects deleted data on refetch. A reset now requires durable
  deletion-intent replay before it can ship.
- **IMPORTANT-3 / #565 reconciliation (accepted).** I over-read a single process
  `sample` as "init blocks main." The code shows `CKSyncEngine.init` is called
  synchronously from the `nonisolated` `prepareEngine`, so it is **not**
  `@MainActor`-isolated and runs off-main (#565 verified `isMainThread==false`).
  The sample is far more consistent with the **main thread pinned by the
  Insights/Analysis conversion storm** while init runs off-main and the
  `@MainActor` `completeStart` continuation is starved. So the lever is to free
  the MainActor / guarantee off-main init — preserving all data — not to slim the
  state. The reset is demoted to a last-resort fallback pending the spike result.

**Endorsed and unchanged:** Layer 2 (2a remove-in-place + 2c delete-time purge +
the tri-state clean-miss/lookup-error/handler-throw safety, §3 ii) — it closes a
real latent data-loss path today and lands regardless of the Layer-1 outcome.

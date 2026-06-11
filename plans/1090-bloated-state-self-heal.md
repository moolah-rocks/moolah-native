# Bloated-state self-heal — design (#1090 / task #12)

Status: **proposal** (design only — implementation BLOCKED on PR-B's deletion
replay; see §8 Dependencies).
Worktree: `.claude/worktrees/design-1090-selfheal` (off `origin/main`).

The dropped "size-gated reset" from the upload-queue-wedge work
(`plans/upload-queue-wedge-fix.md` §2 Layer 3), made **safe** by the #1090
durable deletion journal (PR-A) + a full save re-queue, so a bloated install
**self-heals on launch** with no manual `*.syncstate` deletion.

---

## 1. Problem

A `CKSyncEngine.State` whose pending-record-zone-change list has bloated (the
live wedge artifact was **42.5 MB / ~152 k pending**, almost all stale saves for
a deleted profile) makes `CKSyncEngine.init(configuration:)` spend a long time
deserializing it. Combined with MainActor pressure that delays `completeStart`,
sync effectively never starts. Today the **only** remedy is manual: quit the app
and delete `…/Application Support/<env>/Moolah-v2-sync.syncstate`. That is not
shippable — a user can't do it, and it is the wrong tool (it also discards the
server change tokens, forcing a full re-fetch, with no re-derivation of pending
deletions → silent data divergence; see §5 C-2).

Goal: detect the bloated state at launch and **recover automatically** — discard
the unusable state, then rebuild the pending queue from durable local sources —
without losing a save OR a delete, and without nuking a healthy install.

## 2. The recovery primitive: `stateSerialization: nil` + re-derive

`prepareEngine` (`SyncCoordinator+Lifecycle.swift:113`) already constructs the
engine off-main and treats a missing state file as first launch:

```swift
let savedState = data.flatMap {
  try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0)
}
let configuration = CKSyncEngine.Configuration(
  database: …, stateSerialization: savedState, delegate: delegate)
return PreparedEngine(engine: CKSyncEngine(configuration),
                      isFirstLaunch: savedState == nil)
```

`stateSerialization` carries (a) the pending record-zone changes, (b) the
database/zone **change tokens**, (c) subscription ids, (d) last `userRecordID`.
Passing `nil` yields a *fresh* engine: it re-fetches every zone from scratch (no
change token) and holds no pending changes. That is **already the supported,
exercised path** — `isFirstLaunch == true` runs `queueAllExistingRecordsForAllZones()`
(`SyncCoordinator+Backfill.swift:169`), and `handleEncryptedDataReset`
(`SyncCoordinator+Zones.swift:218`) deletes the state file + re-queues on purpose.

So recovery = **reuse the nil-reset / first-launch machinery**, with one
addition the first-launch path doesn't need: **replay locally-issued deletions**
that the nil-reset can't re-derive (the rows are already gone from GRDB).

Re-fetch-everything is safe: `applyRemoteChanges`'s modificationDate gate (#1085)
+ the `needs_push`/`encoded_system_fields` guards mean a fetched echo never
clobbers an in-flight local edit; re-uploading via the `needs_push` re-queue is
safe because the server dedups on `externalId` and the #1088 wedge-drain handles
any stale save by converting it to a delete.

## 3. Trigger / detection (no manual reset)

**Pre-flight size-gate, before `CKSyncEngine.init`.** `prepareEngine` already
`JSONDecode`s the `Serialization` struct cheaply (the multi-second cost is inside
`CKSyncEngine.init`, not our decode). So we can inspect the decoded state and
decide *before* paying the init cost:

- **Primary signal — pending count.** If `Serialization` exposes
  `pendingRecordZoneChanges` (verify against the SDK; it is `Codable`), count it.
  Recover when `count > BLOAT_THRESHOLD`.
- **Fallback signal — file size.** If the count isn't readable pre-init, gate on
  `Data(contentsOf: stateURL).count > BLOAT_BYTES` (the artifact was 42.5 MB; a
  healthy state is KB–low-MB).

`BLOAT_THRESHOLD` must sit **well above** any legitimate maximum. A large CSV
import legitimately queues thousands of saves; the wedge was 152 k. Propose
`BLOAT_THRESHOLD = 25_000` pending (or `BLOAT_BYTES = 8 MB`), tunable, logged on
every launch as a metric so we can calibrate against real installs before the
gate is allowed to *act* (ship it warning-only first — see §7 rollout).

Rejected alternative — **timeout race** (`CKSyncEngine.init` vs a deadline): init
is not cancellable, the racing task leaks, and a slow-but-healthy init on an old
device would false-trip. The pre-flight count/size gate is deterministic and
cheap.

## 4. Recovery procedure

When the gate trips at launch:

1. **Persist a durable `recoveryInProgress` marker** (UserDefaults, e.g.
   `com.moolah.sync.bloatRecoveryInProgress`) *before* touching anything, so an
   interrupted recovery re-runs (§5 (d)).
2. **Construct the engine with `stateSerialization: nil`** (fresh) — skip handing
   the bloated blob to `init`. Mark the run as first-launch-equivalent
   (`isFirstLaunch = true` / a `didRecover` flag) so the full re-queue fires.
3. **Re-derive SAVES via the FULL re-queue** — `queueAllExistingRecordsForAllZones()`,
   i.e. *every* local record for *every live profile*, NOT the `encoded_system_fields IS NULL`
   subset. (This is the deliberate choice that closes C-1 — see §5 (a).) Live
   profiles only: enumeration goes through `allProfileIds()`, so deleted-profile
   rows are never re-queued (which is what avoids re-bloat — §5 (c)).
4. **Replay DELETIONS from the #1090 journal (PR-B)** — for each durable tombstone
   not yet confirmed-acked, queue a `.deleteRecord`. This is the step nil-reset
   cannot reconstruct (the rows are gone from GRDB), and the whole reason the
   durable journal had to exist first.
5. **Clear `recoveryInProgress`** once steps 3–4 have *enqueued* (not necessarily
   uploaded — durability of the sources covers the rest; §5 (d)).
6. The fresh engine's first `stateUpdate` persists a new, small `*.syncstate`;
   the bloated blob is gone.

## 5. Open risks (stated, not hand-waved)

**(a) C-1 — does nil-reset + re-derive MISS records edited after their last
sync?** A row edited after a successful push has `encoded_system_fields NOT null`
but a stale cloud copy. The normal `queueUnsyncedRecordsForAllProfiles` backfill
(`WHERE encoded_system_fields IS NULL`, `GRDBAccountRepository+Sync.swift:100`)
would **miss** it — it relies on the live `onRecordChanged` hook having queued
the edit. **Recovery closes C-1 by construction**: it uses the *full* re-queue
(step 3, every record regardless of `encoded_system_fields`), so an edited-but-
previously-synced row is re-uploaded; the modificationDate gate (#1085) + latest-
write-wins reconcile it against the re-fetched cloud copy. Cost: recovery re-
uploads everything (bandwidth) — acceptable for a rare recovery path; `externalId`
dedup means the server reconciles rather than duplicates. (Note: C-1 in the
*non-recovery* steady state — a hook-miss on a normal launch — is a **separate**
gap not solved here; flagged for its own follow-up.)

**(b) C-2 — deletion replay vs the save re-queue: ordering / dedup / double-
delete.** Step 3 queues `.saveRecord` for every **live** row; step 4 queues
`.deleteRecord` for every **un-acked tombstone**. The two sets are **disjoint by
recordID** — a record is either present in GRDB (saved) or absent + tombstoned
(deleted), never both — so there is no ordering dependency. The one inconsistent-
state edge (a row both present in GRDB *and* tombstoned) resolves safely: both a
save and a delete for that id coexist in the pending list, and at send the engine
**sends only the delete** (CKSyncEngineState.h; the send-time supersede modeled in
the #1088 drain test) → delete wins, no resurrection. Double-delete is harmless
(`.unknownItem` → treated as success, `SyncErrorRecovery.swift:120`). The journal
replay must dedup against itself (one `.deleteRecord` per id).

**(c) What stops recovery itself from re-bloating?** The bloat we escape is
**stale** (deleted-profile saves that head-of-line-blocked). Recovery re-queues
only **live-profile** records (step 3 enumerates `allProfileIds()`), so the
recovered pending list is proportional to **real** data, which deserializes fine.
The start-time reconciliation (#1091, `SyncCoordinator+StartupReconciliation.swift`)
remains in the pipeline to purge any dead-profile pending that slips in. If real
data alone exceeds the gate (a genuinely enormous account), recovery would loop —
so the gate MUST be set above the legitimate maximum (§3) and the
`recoveryInProgress`-cleared-then-re-tripped case MUST be detected and downgraded
to warning-only rather than looping (a `recoveryAttemptCount` ceiling).

**(d) Idempotency if recovery is interrupted mid-way.** The durable sources are
the source of truth and are re-derived every launch: GRDB `needs_push` (saves)
and the #1090 journal (deletions) both survive a crash. If the app dies after
the nil-init but before the re-queue completes, the new (small) state file may
already be saved → the size-gate won't re-trip → but the persisted
`recoveryInProgress` marker (step 1) forces the full re-queue again on the next
launch; and even absent that, the normal `needs_push` backfill + journal replay
converge. The marker is cleared only after enqueue (step 5). Net: recovery is
idempotent and crash-safe because it derives from durable state, not from
in-memory progress.

## 6. Safety gate — when it fires, and when it MUST NOT

**Fires only when ALL hold:**
- decoded pending count `> BLOAT_THRESHOLD` (or file size `> BLOAT_BYTES`); AND
- iCloud account is **available** (`CloudKitAuthProvider.isCloudKitAvailable`) —
  never recover during sign-out / restricted / no-account; AND
- `recoveryAttemptCount < CEILING` (else downgrade to warning-only — a recovery
  that keeps re-tripping means real data exceeds the gate or a deeper bug; do not
  loop).

**MUST NOT fire when:**
- the state is small/healthy — otherwise every launch would needlessly re-fetch +
  re-upload the entire account (the dominant correctness risk of an over-eager
  gate);
- a zone-purge / `encryptedDataReset` is already in flight — those own their reset
  path (`SyncCoordinator+Zones.swift:196/218`) and already delete the state file;
- mid sign-out / account switch.

**Interaction with `isFirstLaunch`:** recovery *reuses* the first-launch full
re-queue (`queueAllExistingRecordsForAllZones`) but additionally runs the journal
replay (first launch has no prior deletions to replay). The `didRecover` path and
the `isFirstLaunch` path therefore converge on the same save re-queue; the only
delta is the deletion replay.

## 7. Rollout (de-risk the gate)

1. **Observe-only first.** Ship the pre-flight size/count **measurement + log**
   (no action) — close the "no size measurement exists today" gap the wedge plan
   noted. Gather the real distribution of pending counts / state-file sizes.
2. **Calibrate** `BLOAT_THRESHOLD` from that distribution (well above p100 of
   healthy installs).
3. **Enable recovery** behind the calibrated gate, with `recoveryAttemptCount`
   ceiling + structured logging of every recovery (counts before/after, saves
   re-queued, deletions replayed).

## 8. Dependencies

- **PR-A (#1096)** — the durable deletion journal: general / atomic / re-create-
  safe tombstone store + write-on-delete. **Not yet landed on `origin/main`**
  (git log shows only #1090 *follow-ups* `ec2838e1`, `9ceb5e99`, not the journal).
- **PR-B** — the journal **replay** (re-queue `.deleteRecord` for un-acked
  tombstones). Recovery's step 4 *calls* PR-B's replay. **Implementation of this
  design is BLOCKED until PR-B lands.**
- This design (#12 / #1090 self-heal) — the pre-flight size-gate trigger, the
  nil-reset recovery orchestration, the full save re-queue, invoking PR-B's
  replay, and the safety gate.

## 9. C-1 / C-2 — explicitly closed

- **C-1 (edited-after-sync records missed):** CLOSED within recovery by using the
  **full** re-queue (every record, not `IS NULL`); §5 (a). The steady-state
  hook-miss variant is out of scope and flagged separately.
- **C-2 (deletion replay vs re-queue):** CLOSED by the durable-journal replay
  (re-derives the deletions nil-reset loses), the disjoint save/delete sets, the
  send-time delete-wins supersede, and `.unknownItem`→success; §5 (b).

## 10. Files this will touch (when unblocked)

- `SyncCoordinator+Lifecycle.swift` — `prepareEngine`: pre-flight size/count
  measurement + gate; `completeStart`: `didRecover` wiring.
- A new `SyncCoordinator+BloatRecovery.swift` — the gate predicate, the
  `recoveryInProgress` / `recoveryAttemptCount` markers, the recovery
  orchestration (nil-init + full re-queue + PR-B replay invocation).
- `SyncCoordinator+Backfill.swift` — share the full re-queue with the recovery
  path.
- Tests: a bloated-`Serialization` fixture trips the gate; recovery re-queues all
  live records + replays journal tombstones; the gate does NOT trip on a healthy
  state; `recoveryAttemptCount` ceiling stops a loop; interrupted-recovery
  idempotency (durable sources converge).

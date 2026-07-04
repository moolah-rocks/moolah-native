# #1085 — Out-of-order self-echo data loss: root cause & fix design

Status: **proposal** (design only — no implementation in this doc)
Issue: https://github.com/moolah-rocks/moolah-native/issues/1085
Worktree: `.claude/worktrees/fix-1085-sync-echo` (checked out at `main`, post-#1084)
Failing spec test: `origin/spec/sync-out-of-order-echo-loss:MoolahTests/Sync/NeedsPushOutOfOrderEchoLossTests.swift`

---

## 1. Root cause (mechanism-level)

A record that is **created then quickly updated** while the sync engine has a
heavy upload/echo backlog can revert to its *created* version because a **stale
self-echo of the earlier version is applied out of delivery order** onto a row
that is no longer protected.

Precise sequence (single device, no peers — the production symptom: a leg
created as an AUD/income/qty-1 placeholder `V_create`, updated to a real token
leg `V_update`, reverts to the placeholder):

1. `V_create` is written locally, `needs_push = 1`, uploaded in batch *N*.
   On ack, its server system fields (carrying server `modificationDate`
   `T_create`) are cached in the row's `encoded_system_fields`.
2. The row is edited to `V_update`, `needs_push = 1` re-raised, uploaded in a
   **separate** in-flight batch *M*. Its server version has `modificationDate`
   `T_update > T_create`.
3. Under backlog the **confirming echo of `V_update` is fetched/applied first**.
   In `applyBatchSaves` the row is dirty, so it takes the
   system-fields-only + `clearNeedsPushForConfirmingEchoes` path; the field
   compare matches (`current(V_update) == echo(V_update)`) → **`needs_push` is
   cleared**. The row is now *clean*.
4. The **stale echo of `V_create`** (still queued from batch *N*'s separate
   delivery) is fetched/applied **last**. The row is clean, so `splitByDirtiness`
   routes it to the normal `applyGRDBBatchSave` upsert, which **clobbers all
   user fields back to `V_create`**. `V_update` is lost.

### Why every prior fix only moved the window

- **#1079** main-actor pre-snapshot guard — relocated, not closed.
- **#1081 / #1083** transactional in-apply `needs_push` read
  (`splitByDirtiness`) — protects a row *only while it is still dirty*. Step 4
  lands on a *clean* row, so the guard does not engage.
- **#1084** moved the `needs_push` clear off the upload-ack and onto the
  confirming-echo apply path (`clearNeedsPushForConfirmingEchoes`).

#### The false assumption that all three share

`ProfileDataSyncHandler+SystemFields.swift` (`clearNeedsPushForConfirmed` doc)
and `+ApplyGuard.swift` (`clearNeedsPushForConfirmingEchoes` doc) both state,
verbatim:

> …safe because CKSyncEngine delivers fetched changes in server-token order, so
> every earlier-token stale echo has already been processed by then.

**This is false.** Apple explicitly does *not* guarantee fetched-change
ordering (see §7 citations). The clear in step 3 therefore can — and under
backlog does — happen *before* the step-4 stale echo, reopening the clean-path
upsert window. The bug is not "where we clear `needs_push`"; it is that **the
clean apply path has no defence against applying a superseded version**. All
four prior fixes guard the *dirty* window; none guards the *clean* path, which
is where the loss actually happens.

### The same hole exists on the profile-index zone (added after adversary review — I-1)

The per-profile-data handler is **not the only** clean apply path. The
`ProfileIndexSyncHandler` (profile-index zone) has the identical
"clean-row upsert with no version check" shape at **three** sub-sites
(verified against the worktree):

- **Profiles — `applyProfilesGuarded`** (`+NeedsPush.swift:24-45`): same shape
  as the per-profile-data clean path — `dirtyIdsSync → filter clean →
  applyRemoteChangesSync(saved: clean)` with **no** modification-date gate. A
  profile created→renamed under backlog reverts identically.
- **Profiles — index-zone ack-clear** (`clearNeedsPushForConfirmed`,
  `+NeedsPush.swift:60-81`): has **no** `preAckCached == nil` gate (unlike the
  #1084 per-profile-data version), so profile rows clear `needs_push` *more
  eagerly* and reach the unguarded clean path sooner.
- **Instruments — `applyRemoteChanges`** (`ProfileIndexSyncHandler.swift:115-129`):
  applies instrument rows via `instrumentRepository.applyRemoteChangesSync(
  saved:deleted:)` **unconditionally** — no dirty split, no date gate, a full
  server-wins `row.upsert` of every column except `pricingStatus`. Every stale
  instrument echo clobbers all identity/mapping fields.
  **This is the worst case and is directly on the crypto-migration critical
  path:** the migration registers/updates instruments (`register-instrument`,
  and `pricingStatus` mutations) through exactly this path, so an instrument
  create→update reverts under the same backlog that motivates #1085.

The fix must therefore cover **all three** clean-apply sites, not just
`applyBatchSaves`. See §2 "Index-zone sites".

---

## 2. The fix

### Signal that distinguishes a stale echo from a genuine change

`CKRecord.recordChangeTag` is opaque and unorderable (§7), so it cannot order
two versions. But **`CKRecord.modificationDate` can**: it is **server-assigned
and monotonically increasing per record** across that record's saves, and it is
present on every full record CloudKit delivers (it lives in the system-fields
blob — encoded under the archive key `RecordMtime`; verified empirically, §6).

Crucially we only ever compare **two versions of the *same* record**, both
timestamped by the **same server clock** — so cross-device clock skew is
irrelevant, and we never compare dates across different records.

This is exactly Apple's canonical defence `setLastKnownRecordIfNewer()`, applied
at every apply site in `apple/sample-cloudkit-sync-engine` (§7): *adopt the
incoming record only when it is newer by `modificationDate`; otherwise "the
other record is older than the one we already have."*

### Apply-site change (the core fix)

In `applyBatchSaves` (`ProfileDataSyncHandler+ApplyRemoteChanges.swift`), add a
**modification-date gate on the clean path**, alongside the existing
`splitByDirtiness`:

```
for (recordType, ckRecords) in grouped {
  ids        = ckRecords.compactMap(uuid)
  dirty      = dirtyIds(recordType, ids, in: db)
  cachedMod  = cachedModificationDates(recordType, ids, in: db)   // NEW: id -> Date?
  (clean, echoed) = splitByDirtiness(ckRecords, dirty)

  // NEW — reject superseded echoes on the clean path:
  (applicable, staleRejected) = splitByModificationDate(clean, incoming, cachedMod)

  if !echoed.isEmpty { …system-fields-only + clearNeedsPushForConfirmingEchoes… }  // unchanged
  applyGRDBBatchSave(recordType, applicable, systemFields, in: db)                 // was: clean
  // staleRejected: skip entirely — older than what we hold; do NOT regress fields
  //                and do NOT adopt their (older) system fields.
}
```

`splitByModificationDate` decision per clean record (let `inc =
record.modificationDate`, `cur = cachedMod[id]`):

| `cur` (cached) | `inc` (incoming) | decision | rationale |
|---|---|---|---|
| `nil` | any | **apply** | first server version for this row — nothing to protect (fail-open) |
| non-nil | `nil` | **apply** | defensive fail-open; fetched records always carry a date, so unreachable in production — see §4 |
| non-nil | `inc > cur` | **apply** | strictly newer — genuine forward progress |
| non-nil | `inc <= cur` | **reject** | older-or-equal → superseded stale echo |

The cached date is read from the row's existing `encoded_system_fields` blob
**inside the same write transaction** (decode → `.modificationDate`). The
in-transaction reader already exists as
`cachedSystemFields(recordType:id:in:)` in
`+CurrentRecordInTransaction.swift`; add a batched
`cachedModificationDates(recordType:ids:in:)` (one `WHERE id IN (…)` per type)
to keep the gate O(1) queries per record type rather than O(rows).

Because `applyGRDBBatchSave` stamps the row's cached blob **from the applied
record's own system fields** (via the `systemFields` lookup built from each
incoming `record.encodedSystemFields`), the cached date **advances to the
applied version's date on every apply** — so once a device holds `V_final`, no
older echo can pass the gate again.

### Why this closes the bug independent of `needs_push` clear timing

Step 4 of §1: the stale `V_create` echo has `inc = T_create`; the row's cached
date is now `T_update` (set when the `V_update` echo was applied in step 3).
`T_create < T_update` → **rejected**. The premature `needs_push` clear in step 3
is now irrelevant to correctness — the date gate is the load-bearing guarantee.
This is **defence-in-depth**: it does not depend on fetch ordering, on
`needs_push`, or on the confirming-echo clear.

### Interaction with the existing `needs_push` machinery — it **stays**

`needs_push` keeps two distinct jobs, both still required:

1. **Upload driver.** It is what tells CKSyncEngine (via
   `pendingRecordZoneChanges`) there is an unsent local edit. Unchanged.
2. **Unsent-local-edit apply guard.** While a local edit is written but **not
   yet uploaded**, the row's cached date is still the *old* acked version's
   (`V_update` has no server date yet). A genuine **peer** change with a newer
   date would *pass* a date-only gate and **overwrite the un-uploaded local
   edit** — data loss of the local edit. The dirty path
   (`splitByDirtiness` → system-fields-only, fields untouched) is what prevents
   that, deferring resolution to the normal upload/`serverRecordChanged`
   conflict path. The date gate **cannot** replace this; it complements it.

So the layering is:

- **Dirty row (unsent local edit):** protected by `needs_push` (fields never
  overwritten). *Unchanged.*
- **Clean row (fully round-tripped):** protected by the **new date gate**
  (older-or-equal echoes rejected). *This is the fix.*

The `#1084` `clearNeedsPushForConfirmingEchoes` clear **stays** (it is harmless
and still correct), but its **load-bearing rationale changes**: it no longer
relies on fetch-order. The false "server-token order" sentences in
`+ApplyGuard.swift` and `+SystemFields.swift` must be **rewritten** to cite the
date gate as the actual guarantee. (Optional, out-of-scope follow-up: with the
date gate in place, the ack-clear's `preAckCached == nil` gating in
`clearNeedsPushForConfirmed` is no longer needed for safety and could be
simplified — call out but do not do here.)

The dirty path's system-fields-only write is left as-is. Adopting an older
tag there is at worst a harmless extra `serverRecordChanged` on the next upload
(self-healing), never data loss; a no-regress check there is optional hardening.

### Index-zone sites (added after adversary review — I-1)

The same strict-`>` modification-date gate extends to the profile-index zone.
**Verified prerequisite:** both `ProfileRow` and `InstrumentRow` persist
`encoded_system_fields` and `partitionSaved` copies each incoming record's blob
onto the converted row (`+Instruments.swift:27,36`), so for both types a cached
date is **readable** (from the stored row's blob) and **advances on apply** (the
applied row's blob is written by the upsert). The gate is therefore feasible at
all three sites without new schema.

**Profiles (`applyProfilesGuarded`).** UUID-keyed, and the row already has a
`needs_push` dirty guard. Mirror the per-profile-data design exactly: keep the
dirty split, and add the date gate to the **clean** subset before
`applyRemoteChangesSync(saved: clean)` — apply a clean profile row only if its
incoming `modificationDate` is strictly `>` the stored row's cached date
(`nil` cached → apply). The eager index-zone ack-clear (no `preAckCached==nil`
gate) becomes safe for the same reason the per-profile-data clear does: the
clean-path date gate is now the load-bearing guarantee, so the earlier clear no
longer matters. (Optionally align it with the per-profile-data gating; not
required once the date gate is in.)

**Instruments (`GRDBInstrumentRegistryRepository.applyRemoteChangesSync`).**
String-keyed (by `id`, e.g. `"AUD"`, contract address); **no `needs_push`
column** — instruments use field-level merges instead, not a dirty guard. The
gate piggybacks on the `fetchOne(existing)` the method **already performs** for
the `pricingStatus` merge:

```
for each incoming row:
  existing = fetchOne(id)                       // already done today
  merged   = PricingStatusMerge(local: existing?.pricingStatus, incoming: row)  // already done
  curDate  = existing?.encodedSystemFields → modificationDate
  incDate  = row.encodedSystemFields → modificationDate
  if existing != nil && curDate != nil && incDate != nil && incDate <= curDate {
     // STALE echo: do NOT revert identity/mapping fields, do NOT regress blob.
     // BUT still apply the pricingStatus merge result (see below).
     if merged != existing.pricingStatus {            // M-6: skip the no-op write
       write ONLY pricing_status = merged on the existing row
     }
  } else {
     row.pricingStatus = merged; row.upsert(database)   // current behaviour
  }
```

**`pricingStatus` is exempted from the date gate — this is essential.**
`PricingStatusMerge` is a deliberately **recency-independent** field CRDT (a
user's `.spam` classification is *sticky* and must survive an auto-resolver's
later `.priced` from another device — that is the whole reason the merge
exists). A naive *record-level* date gate that rejected a stale echo wholesale
would skip that merge and could leave two devices **divergent** on
`pricingStatus` (one `.spam`, one `.priced`). So the gate governs only the
**identity / provider-mapping fields and the cached system-fields blob** (the
fields that actually revert under #1085); `pricingStatus` always flows through
its existing merge regardless of record date. This both fixes the identity
reversion **and** preserves spam-stickiness convergence.

Note instruments have no `needs_push`, so there is no dirty-path guard to
preserve here — the date gate is purely additive (it can only *reduce*
clobbering relative to today's unconditional server-wins upsert), so it cannot
introduce a new local-edit loss.

---

## 3. Multi-device convergence argument

Claim: every device converges to `V_final` (the highest-`modificationDate`
server version) regardless of fetch delivery order.

1. The server assigns a **total order** of `modificationDate`s per record across
   its saves; `V_final` has the maximum.
2. A device applies an incoming version on the clean path **iff** it is strictly
   newer than the version it currently holds. Applying advances the cached date
   to the applied version (§2).
3. Therefore a device's held version is **monotonically non-decreasing** in
   `modificationDate`: it never moves backward (older/equal rejected) and only
   moves forward to strictly-newer versions.
4. CKSyncEngine **eventually** delivers `V_final` to every device (delivery is
   guaranteed; only *order* is not). When it arrives it is ≥ everything the
   device has seen, so it is applied (or is already held).
5. Stale/superseded echoes delivered before or after `V_final` are rejected and
   cannot revert it.
6. Unsent local edits upload, become a server version with a new maximum date,
   echo back, and all devices converge to that. Concurrent peer edits resolve by
   server acceptance order (last writer gets the maximum date) → all converge.

Convergence depends only on the **server's per-record date total order**, never
on delivery order — which is precisely the property #1084 wrongly assumed of
fetch tokens, now correctly sourced from `modificationDate`.

**Instruments split into two converging layers:** identity/mapping fields
converge by the date gate exactly as above (to `V_final`); `pricingStatus`
converges by its own `PricingStatusMerge` CRDT, which is intentionally
recency-independent (sticky `.spam`) and is **not** subject to the date gate
(§2). The two are orthogonal columns, so each converges on its own rule.

Residual: see §4 (the equal-date tie).

---

## 4. Modification-date tie / granularity / clock-skew analysis

- **Clock skew: not applicable.** `modificationDate` is **server-assigned**;
  every version of a given record is timestamped by the same server clock, and
  we only ever compare versions of the *same* record. No device clock is
  involved. This is strictly safer than any local-timestamp scheme.

- **Granularity.** `modificationDate` is sub-second. Two *sequential* saves of
  the same record are two separate server round-trips, so in practice they
  receive **distinct** timestamps. The real bug (`T_create` vs `T_update`) is a
  strict inequality; the gate fixes it with the common `inc < cur` branch.

- **The tie (`inc == cur`, fields differ).** Two genuinely different versions
  sharing one `modificationDate` is near-unreachable for sequential saves but
  not provably impossible. Chosen tie-breaker: **reject on tie** (apply only on
  strict `>`). Justification:
  - For the **stale-echo** case a tie is *correct to reject* (the echo is the
    superseded version; rejecting preserves the newer local/cached version).
  - The only cost is the symmetric **false negative**: a genuine peer change
    that happens to share the cached version's exact server timestamp is
    dropped → temporary single-record **divergence**, **not data loss**, and it
    **self-heals** on that record's next modification (which gets a newer date)
    or any full re-fetch.
  - Per the project's non-negotiable "data loss" bar, a self-healing
    divergence that requires a same-instant collision is strictly preferable to
    reopening a silent data-loss window (which `>=` would do).

  This residual is the single thing I most want the adversary to attack. A
  stronger-but-heavier alternative (not proposed): on an equal-date / differing
  -fields collision, treat it as a conflict and force a re-push rather than
  silently keep the local copy. Flagged, not chosen, to avoid over-engineering.

- **`nil` dates.** Fail-open (apply) — see the §2 table. Fetched server records
  always carry a date; a `nil` incoming date is unreachable in production, and
  failing open avoids ever rejecting a real change because of a missing date.
  (Consequence: the spec tests, which fabricate dateless records, **must** stamp
  real dates to exercise the gate — see §5.)

---

## 5. Test changes

### 5a. `NeedsPushOutOfOrderEchoLossTests` — **must carry real modification dates**

As written the spec test fabricates both echoes via `row.toCKRecord(in:)`,
which builds a **fresh local `CKRecord` with `modificationDate == nil`**
(verified §6). With the date gate, `nil` cached date → fail-open → the stale
echo is still applied → **the loss tests would still fail even with the fix**.
The tests therefore *must* be amended so `V_create` and `V_update` carry
**distinct server `modificationDate`s** (`T_create < T_update`), exactly as
production does. Without this the fix and the test are inconsistent.

**How to stamp a `modificationDate` on a fabricated `CKRecord`** (empirically
verified end-to-end in §6 — survives the production
`encodedSystemFields` → `fromEncodedSystemFields` secure-coding round-trip):

```swift
// Test-only helper (UITestSupport or the sync test support file).
// Stamps a server modificationDate onto an otherwise-local CKRecord by
// writing the system-fields archive's `RecordMtime` key, then re-applying
// the user fields (encodeSystemFields drops them on decode).
extension CKRecord {
  func withModificationDate(_ date: Date) -> CKRecord {
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    encodeSystemFields(with: coder)
    coder.encode(date, forKey: "RecordMtime")   // CKRecord's archive key for mtime
    coder.finishEncoding()
    let unarchiver = try! NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
    unarchiver.requiresSecureCoding = true
    let stamped = CKRecord(coder: unarchiver)!
    for key in allKeys() { stamped[key] = self[key] }   // re-apply user fields
    return stamped
  }
}
```

Notes / guard-rails for the helper:
- `RecordMtime` is an internal CKRecord archive key, so the helper **must**
  assert `result.modificationDate != nil` (fail loudly if Apple ever renames it)
  and live in test support only — production never stamps dates.
- The value **must be an `NSDate`/`Date`** — encoding ms-as-`Int64`/`Double`
  decodes to `nil` (verified §6, techniques A/B/D all failed; C succeeded).

Amend each loss test:

```swift
let t0 = Date(timeIntervalSince1970: 1_700_000_000)
let vCreateEcho = vCreateRow.toCKRecord(in: Self.zoneID).withModificationDate(t0)
_ = try repo.setEncodedSystemFieldsSync(id: id, data: vCreateEcho.encodedSystemFields)
…
let vUpdateEcho = vUpdateRow.toCKRecord(in: Self.zoneID)
  .withModificationDate(t0.addingTimeInterval(60))   // strictly newer
```

After amendment both `legUpdateSurvivesOutOfOrderEcho` and
`…UnderBatchLoad` pass: step-3 applies `V_update`'s echo (cache → `t0+60`),
step-4 `V_create` echo (`t0`) is `< t0+60` → rejected → row stays at qty 200.

### 5b. `syncedCleanRowAppliesGenuineRemoteChange` — **stays green**

This load-bearing test (a clean, already-synced row must accept a genuine peer
change) passes **either way**: today its cached blob is built from a local
`toCKRecord` → cached date `nil` → fail-open → genuine change applied.
**Recommended** (for rigor, not required): amend it to give the cached version
an older stamped date and the peer change a strictly-newer one, so it exercises
the gate's "newer → apply" branch explicitly rather than the `nil` fail-open.

### 5c. New unit tests to add

- **Clean-path reject:** clean row cached at date `T2`; deliver an echo at
  `T1 < T2`; assert fields unchanged (direct test of the gate, no `needs_push`).
- **Tie reject:** clean row cached at `T`; deliver a differing-field echo at `T`;
  assert the cached version is kept (documents the §4 tie decision).
- **Unsent-edit peer guard (regression-lock for "needs_push stays"):** dirty row
  (unsent local edit), deliver a *newer-dated* peer change; assert the local
  fields are **not** overwritten (proves the date gate did not replace the
  dirty-path guard).
- **Cached-date advances:** apply a genuine newer change, then a stale echo;
  assert the stale echo is rejected (proves the apply stamped the new date).

### 5d. Existing byte-for-byte / round-trip tests

`ProfileIndexSyncRoundTripTests.profileApplyRemoteChangesPreservesEncodedSystemFieldsByteForByte`
and friends are unaffected — they deliver to clean rows with `nil` cached dates
(fail-open) and assert blob preservation, which the gate does not change.

### 5e. Index-zone reproduction tests (added — I-1)

Analogues of the leg tests, one per index-zone site:

- **Instrument register→update revert** (on the migration's critical path):
  drive an instrument through create (`V_create`) then update (`V_update`,
  changed mapping/decimals/ticker) with stamped dates `T1 < T2`, cache
  `V_create`, then deliver `applyRemoteChangesSync` the `V_update` echo
  followed by the stale `V_create` echo; assert the identity/mapping fields
  stay at `V_update`. Add a sibling asserting a stale echo carrying an **older**
  `pricingStatus` does **not** undo a sticky `.spam` (i.e. `pricingStatus`
  still merges while identity fields are gated).
- **Profile create→rename revert:** create `V_create`, rename to `V_update`
  (dated `T1 < T2`), deliver the `V_update` confirming echo (clears
  `needs_push`) then the stale `V_create` echo; assert the name stays renamed.

Both fabricate dated records with the §5a `withModificationDate` helper.
String-keyed instrument records stamp the same way (the helper is
record-name-agnostic).

### 5f. Within-batch dedup (M-2) — **UUID-keyed sites only** (scoped per I-2)

Before applying, **dedup the clean set to the max-`modificationDate` per record
id** — but **only at the UUID-keyed gate sites** (per-profile-data
`applyBatchSaves`, and index-zone profiles). There each record is a whole-row
server-wins upsert with no field-level CRDT, so collapsing duplicates to the
newest date is correct and is cheap insurance: if a batch ever carried two
versions of one id, last-write-by-date wins rather than last-by-array-order.
State the "one fetch event coalesces to one version per record" assumption
explicitly in code. Test: feed two versions of one id in a single batch (newest
not last in array) and assert the newest wins.

**Do NOT dedup at the instrument site.** Dedup-to-max would discard the dropped
duplicate **entirely**, so its `pricingStatus` would never reach
`PricingStatusMerge` — e.g. a same-batch `[V_create(T1, .spam),
V_update(T2, .priced)]` would collapse to `.priced`, losing the sticky `.spam`.
That is exactly the CRDT regression the pricingStatus exemption (§2) exists to
prevent. The instrument site is **already within-batch-correct in either array
order without dedup**: the existing per-row `fetchOne` + `PricingStatusMerge` +
upsert loop means each iteration sees the prior iteration's upsert, so the
identity/mapping fields converge to the newest-dated version (via the gate)
**and** every duplicate's `pricingStatus` folds through the merge. (If a future
change ever wants dedup here, it must first fold `pricingStatus` across the
dropped duplicates via `PricingStatusMerge`, not discard them.)

Test (instrument within-batch): deliver a same-batch
`[older .spam, newer .priced]` pair for one id in **both** array orders and
assert the identity fields end at the newer version **and** `pricingStatus`
stays sticky `.spam`.

---

## 5.5 Implementation checklist (M-1, M-3)

- **M-3 — rewrite the false ordering comments.** The "CKSyncEngine delivers
  fetched changes in server-token order" rationale is wrong and must be replaced
  (cite the date gate) in **all** of: `+ApplyGuard.swift`
  (`clearNeedsPushForConfirmingEchoes`), `+SystemFields.swift`
  (`clearNeedsPushForConfirmed`), and the index-zone equivalents in
  `ProfileIndexSyncHandler+NeedsPush.swift`.
- **M-1 — decode cost, do not add a column now.** The real per-batch cost of the
  gate is N× `NSKeyedUnarchiver` + `CKRecord(coder:)` decodes inside the write
  transaction (rough order ~25–50 ms for a ~514-record batch), not query count.
  Acceptable for a one-time migration. Add a benchmark of the decode cost and
  **only** consider a stored, indexed `server_modification_date` column if it
  actually shows up as a regression. Do **not** add the column speculatively.
- Add the batched cached-date readers:
  `cachedModificationDates(recordType:ids:in:)` (per-profile-data + profiles,
  one `WHERE id IN (…)` per type) and the string-keyed instrument variant
  (piggyback on the existing `fetchOne`/`fetchRowsSync`).
- Keep the `nil`-cached / `nil`-incoming **fail-open** behaviour (§2 table) at
  every site, so genuine first-syncs and the round-trip tests are unaffected.
- **M-5 — NON-GOAL (deletions).** This fix governs out-of-order *saves* only.
  Out-of-order *deletions* (a stale delete echo arriving after a re-create, and
  tombstone-vs-save ordering generally) are a separate, pre-existing class
  **consciously out of scope** for #1085 — `modificationDate` does not exist on a
  delete event, so the same signal does not apply. Call this out explicitly so a
  future reader does not assume the gate covers it.
- **M-6 — skip no-op pricing_status write.** In the instrument stale branch,
  only write `pricing_status` when `merged != existing.pricingStatus`, to avoid
  a redundant write (and a redundant cache invalidation) on the common case
  where the stale echo's status matches.

---

## 6. Refuted / amended from the starting hypothesis + empirical evidence

- **CONFIRMED** the issue's own recommendation (track this device's uploaded
  change tags in new schema, reject recognized self-echoes) is the **wrong
  layer**: (a) it gives **peers zero protection** under the identical failure
  mode (a peer never uploaded `V_create`, so self-tag tracking can't recognize
  its stale echo), and (b) it needs new schema for a signal
  (`modificationDate`) CloudKit already ships on every record. The date gate
  protects self-echoes and peer echoes **identically** and needs **no schema
  change**.

- **CONFIRMED** `recordChangeTag` is unusable for ordering (opaque, §7); the
  hypothesis's pivot to `modificationDate` is correct.

- **AMENDED — `needs_push` does not "shrink to the unsent window" as a code
  change; it stays exactly as is.** The hypothesis framed needs_push as covering
  "only the genuinely-unsent-local-edit window." That is its *role*, but no code
  is removed: the dirty-path guard is still required to stop a *newer* peer
  change clobbering an un-uploaded local edit (a date-only gate would wrongly
  apply it). The date gate is **added** to the clean path; the needs_push guard
  is **retained** on the dirty path. (Optional simplification of the ack-clear's
  `preAckCached==nil` gating is noted as out-of-scope follow-up.)

- **CONFIRMED & RESOLVED the test-consistency risk** the lead flagged.
  Empirically established in this repo's CloudKit via `mcp__xcode__ExecuteSnippet`:
  1. `row.toCKRecord(in:)` yields `modificationDate == nil` (fresh local record).
  2. CKRecord's system-fields keyed archive uses **`RecordMtime`** (mod) and
     `RecordCtime` (creation); date fields are `$null` when unset.
  3. Encoding `RecordMtime` as a **`Date`** then decoding yields a record with
     that `modificationDate`; encoding it as `Int64`/`Double` (ms or s) yields
     `nil`.
  4. The stamped date **survives** the production
     `encodedSystemFields` → `fromEncodedSystemFields` (secure-coding) round-trip
     and the gate's `<`/`>` comparisons.
  5. Re-applying user fields onto the stamped record preserves **both** the date
     and the fields.
  ⇒ The §5a helper is sound, and the loss tests **cannot** pass on the fix
  without it (the gate fails open on `nil` dates). Fix and test are now
  consistent.

- **NOTED residual (for the adversary):** the equal-date tie (§4) — reject-on-tie
  trades a near-unreachable, self-healing divergence for closing the data-loss
  window. This is the deliberate, and only, correctness compromise.

- **ADDED after adversary review (I-1) — index-zone coverage, with the
  instrument-path question resolved.** Verified in the worktree:
  - `ProfileRow` and `InstrumentRow` **both persist `encoded_system_fields`**,
    and `partitionSaved` copies each incoming record's blob onto the converted
    row — so a cached date is readable AND advances on apply at all three index
    -zone sites. The gate needs **no schema change**.
  - Instruments are **string-keyed** (`id`) and have **no `needs_push`** column;
    the gate keys by string id and piggybacks on the `fetchOne` the instrument
    apply already does for the `pricingStatus` merge.
  - **Newly surfaced interaction (resolved):** `PricingStatusMerge` is a
    recency-independent field CRDT (sticky `.spam`). A record-level date gate
    that rejected stale echoes wholesale would **regress** pricingStatus
    convergence (devices could diverge `.spam` vs `.priced`). Resolution: the
    gate governs only the identity/mapping fields + system-fields blob;
    `pricingStatus` always flows through its existing merge. See §2 "Index-zone
    sites".

---

## 7. Citations

1. CKSyncEngine fetched-changes ordering is **not** guaranteed:
   *"Although CloudKit doesn't guarantee the order of fetched record zone
   changes, the typical order … is oldest to newest."*
   https://developer.apple.com/documentation/cloudkit/cksyncengine-5sie5/event/fetchedrecordzonechanges
2. `CKServerChangeToken` is opaque: *"Don't infer any behavior or order from a
   token's contents."*
   https://developer.apple.com/documentation/cloudkit/ckserverchangetoken
3. Apple's canonical defence `setLastKnownRecordIfNewer()` (adopt only if newer
   by `modificationDate`, at every apply site):
   https://github.com/apple/sample-cloudkit-sync-engine/blob/main/SyncEngine/SyncedDatabase.swift
4. Delivered server changes are **full records**, so a stale echo clobbers all
   fields (motivates a gate, not field-level merge) — same sample / CloudKit
   record-zone-changes semantics.
5. `CKRecord.modificationDate` (server-assigned record metadata):
   https://developer.apple.com/documentation/cloudkit/ckrecord/modificationdate
6. Empirical (`RecordMtime` archive key, `Date`-typed, secure-coding
   round-trip): established in-repo via `mcp__xcode__ExecuteSnippet` against
   `Backends/CloudKit/Sync/CloudKitRecordConvertible.swift`, 2026-06-10 (§6).

Caveat (carried from the research pass): no Apple source *positively* documents
a token fetch replaying a superseded older same-record payload after a newer
one. The justification is the **absence of any precluding ordering guarantee**
(cit. 1, 2) plus Apple's own **defensive design** (cit. 3). Treat the gate as a
defensive-correctness requirement, which is also exactly how Apple frames it.

# Safe bloated-state recovery (self-heal) — #1090 Design 2 / #12

Builds on the merged #1090 deletion journal + replay (PR-B). Size-gates a
pathological CKSyncEngine state that would stall `CKSyncEngine.init`, rebuilds
the engine with `nil` state (instant init) → the install self-heals on launch
with no manual `syncstate` deletion. Made delete-safe by the journal replay +
a **recovery-scoped tombstone shield**; save-complete via the
`isFirstLaunch=true` → `queueAllExistingRecordsForAllZones` path.

**Rollout decision (user):** ship ENABLED with `BLOAT_BYTES = 24 MB`, plus
always-on `Data.count` logging.

## Mechanism

1. **Size-gate (`prepareEngine`).** `start()` computes `allowRecovery` on the
   MainActor (entitlements present, account not known-unavailable, attempt count
   < ceiling) and passes it + the threshold into `prepareEngine`. `prepareEngine`
   always logs `Data.count`; if `allowRecovery && count > BLOAT_BYTES` it builds
   the engine with `stateSerialization: nil` and returns
   `recoveryOutcome = .recovered` + `isFirstLaunch = true`. Below threshold →
   `.healthy`; above but skipped (ceiling/account) → `.bloatedButSkipped`
   (state passed through; off-main init absorbs the stall; loud warning).

2. **Attempt ceiling + re-arm.** `recoveryAttemptCount` in UserDefaults
   (pattern: `backfillScanCompleteKeyPrefix`). `completeStart`: `.recovered` →
   increment; `.healthy` → reset to 0 (re-armable months later); CEILING = 3.

3. **Save-completeness (closes C-1).** `.recovered` ⇒ `isFirstLaunch = true` ⇒
   `runZoneSetup` runs `queueAllExistingRecordsForAllZones` (→
   `collectGRDBRecordIDs(.all)`, every row incl. `needs_push=1` edited-after-sync).
   NOT the `IS NULL` backfill.

4. **Delete-safety (closes C-2, normal).** The merged journal replay re-issues
   every unconfirmed deletion on the post-reset start.

5. **Recovery-scoped tombstone shield (closes C-2 under the token-less refetch).**
   On `.recovered`, `completeStart` spawns `recoverySnapshotTask` (set BEFORE the
   engine is installed) that reads every journal (index + each profile DB),
   resolves the union of tombstone `CKRecord.ID`s into `recoveringDeletions`. The
   fetched-change apply path, while the shield is active, **awaits that task**
   (race-free) and, for any incoming saved record whose id ∈ `recoveringDeletions`,
   **skips the upsert AND the D1-b journal clear** — so the replayed
   `.deleteRecord` wins on both local row and server, and a deleted-but-
   un-propagated record re-delivered by the full refetch is not resurrected. Each
   id is released from the shield as its `.deleteRecord` is confirmed
   (clear-on-confirm); the shield deactivates when the set empties. Scoped: a peer
   re-create of an id NOT in the snapshot upserts + clears normally.

6. **Recovery never wipes the journal.** Recovery resets ONLY engine state
   (`nil`); it never calls `deleteLocalData`/`clearAll` (those are sign-out /
   account-switch / zone-purge teardown). Provable by construction.

## Files

- `SyncCoordinator.swift` — state: `recoveringDeletions: Set<CKRecord.ID>`,
  `recoverySnapshotTask`, `isRecoveryShieldActive`; recovery-count key.
- `SyncCoordinator+BloatRecovery.swift` (NEW) — `BLOAT_BYTES`, `CEILING`, pure
  `bloatGateOutcome(...)`, attempt-count helpers, `buildRecoveryDeletionSnapshot`,
  shield accessors + release, pure `shieldedSaves(_:shield:)`.
- `SyncCoordinator+Lifecycle.swift` — `start()` gate inputs; `prepareEngine`
  (params + size log + outcome); `completeStart` outcome handling + arm shield;
  `runZoneSetup` unchanged (isFirstLaunch already drives save-complete).
- `SyncCoordinator+DeletionReplay.swift` — extract `resolveAllJournalDeletions`
  (shared by replay + snapshot); release shield ids in `clearConfirmedReplayedDeletions`.
- `SyncCoordinator+RecordChanges.swift` — apply-path filter (data + index) via the
  shield, race-free await.
- `PreparedEngine` — add `recoveryOutcome`.

## Tests (Design 2) — TDD, red-first

1. **Size-gate** (pure): oversized count + allow → `.recovered`; below → `.healthy`;
   above + !allow → `.bloatedButSkipped`.
2. **Attempt-ceiling**: recover→increment; healthy→reset 0; N≥CEILING consecutive
   above-threshold → `.bloatedButSkipped` (stops firing); re-armable after healthy.
3. **Save-complete reset (C-1)**: edited-after-sync (`needs_push=1`, blob≠NULL) +
   never-synced row → recovery → BOTH re-queued.
4. **Delete-safe reset (C-2)**: journaled deletion replayed; no resurrection.
5. **Refetch-resurrection CRITICAL (both orderings)**: deleted-but-un-propagated X
   re-delivered by refetch, refetch-before-replay AND replay-before-refetch →
   X NOT resurrected locally or server-side, tombstone not prematurely cleared.
6. **Shield is scoped**: peer re-create of id NOT in snapshot → upserts + clears.
7. **Shield filter** (pure `shieldedSaves`): partitions saved records by the set.
8. **End-to-end self-heal**: wedged fixture → recovered → queue drains.

## Open items for the adversary

- BLOAT_BYTES = 24 MB calibration (false-positive = one-time refetch, data-safe).
- Shield lifetime = until each tombstone's `.deleteRecord` is confirmed (per-id
  release); apply path awaits the snapshot task (race-free vs the auto-fetch).
- Account gate at `prepareEngine` time uses entitlements + not-known-unavailable
  (the async account probe hasn't run yet); recovery is data-safe regardless.

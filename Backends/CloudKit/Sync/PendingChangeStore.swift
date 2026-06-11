@preconcurrency import CloudKit

/// The slice of `CKSyncEngine.State` the upload-batch builder depends on:
/// reading the pending record-zone changes and adding/removing them.
///
/// Extracting this lets the drain path (`nextRecordZoneChangeBatch`) run against
/// an in-memory double in tests instead of a live `CKSyncEngine`, which has no
/// constructible test instance. Production passes the real `syncEngine.state`,
/// which already implements every member verbatim — the conformance below is an
/// empty body, so there is zero behavioural or allocation overhead in the
/// shipping path.
///
/// Intentionally minimal: only the three members the batch builder touches. Do
/// not grow it toward a general `CKSyncEngine.State` facade — a wider surface is
/// both more to keep faithful and more likely to silently shadow a future Apple
/// API change.
///
/// ## What the drain relies on (and what a faithful double must model)
/// The wedge-drain fix (#1087) does NOT lean on any subtle ordering rule: a stale
/// `.saveRecord` whose row no longer exists is dropped with an explicit
/// `remove(.saveRecord)`, and a compensating `.deleteRecord` is added for it. So
/// the load-bearing behaviours a test double must reproduce are just:
/// - **`remove` deletes the matching changes**, which is what clears the head of
///   the queue and lets the next buildable batch through; and
/// - **insertion order is stable** across `add`/`remove`, because
///   `dedupedPendingChanges` walks the list in order and `prefix(400)` takes the
///   head — the wedge only reproduces if the dead head stays at the front.
///
/// `add` additionally "deduplicat[es] as necessary" (Apple,
/// `CloudKit.framework/Headers/CKSyncEngineState.h`). The double models same-type
/// dedup but deliberately NOT opposite-type supersede (a `.deleteRecord(X)`
/// dropping a pending `.saveRecord(X)`): the drain never adds a delete over a live
/// save (it removes the save first), and an in-flight save+delete for one id can
/// genuinely coexist (#1090). See `InMemoryPendingChangeStore` for the rationale.
///
/// `: Sendable` records that a conformer is a reference type confined to the main
/// actor and safe to hand to the `@MainActor` drain path. Both conformers satisfy
/// it: `CKSyncEngine.State` is `Sendable` per CloudKit's header audit, and
/// `InMemoryPendingChangeStore` is `@MainActor` (hence `Sendable`).
@MainActor
protocol PendingChangeStore: Sendable {
  var pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange] { get }

  func add(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
  func remove(pendingRecordZoneChanges: [CKSyncEngine.PendingRecordZoneChange])
}

// `CKSyncEngine.State` already declares all three members with these exact
// signatures (`add(pendingRecordZoneChanges:)` / `remove(pendingRecordZoneChanges:)`
// via `NS_SWIFT_NAME`, and the read-only `pendingRecordZoneChanges` array), so
// the conformance is satisfied with no implementation.
//
// No `@retroactive` needed: that attribute is only for conforming an external
// type to an *external* protocol. `PendingChangeStore` is declared in this
// module, so conforming CloudKit's `CKSyncEngine.State` to it is a first-party
// conformance and cannot clash with another module's.
//
// Isolation soundness: `CKSyncEngine.State`'s members are effectively
// `nonisolated` (ObjC-bridged), so conforming it to a `@MainActor` protocol is a
// widening the `@preconcurrency import` accepts without a witness-mismatch
// diagnostic. It is sound only because every call site lives inside a
// `@MainActor` method (the whole drain path, and `SyncCoordinator` itself, are
// main-actor-isolated). Any FUTURE code that holds a value as `any
// PendingChangeStore` from a non-`@MainActor` context must hop
// (`await MainActor.run`) before calling these members.
extension CKSyncEngine.State: PendingChangeStore {}

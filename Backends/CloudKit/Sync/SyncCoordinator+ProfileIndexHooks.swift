import CloudKit
import Foundation

// Registry hook wiring and observation setup for `SyncCoordinator`. Covers
// both the profile-index repository hooks (invoked from `SyncCoordinator.init`)
// and the canonical-resolver observation task started at bootstrap.
extension SyncCoordinator {

  /// Starts observing `registry` for changes and keeps `sharedCanonicalResolver`'s
  /// dynamic alias map up to date. The created `Task` is stored privately and
  /// cancelled by `stop()`. Called once at bootstrap after coordinator construction.
  func startCanonicalResolverObservation(
    registry: any InstrumentRegistryRepository,
    changes: AsyncStream<Void>
  ) {
    guard let resolver = sharedCanonicalResolver else { return }
    canonicalResolverObservationTask = resolver.startObserving(
      registry: registry, changes: changes)
  }

  /// Installs repository-side hooks so app-side mutations (`upsert` /
  /// `delete` on `GRDBProfileIndexRepository`) automatically queue
  /// CKSyncEngine pending changes. Runs at the end of `init` so every
  /// stored property on `self` exists before the closures capture it.
  func wireProfileIndexHooks() {
    let zoneID = profileIndexHandler.zoneID
    containerManager.profileIndexRepository.attachSyncHooks(
      onRecordChanged: { [weak self] id in
        Task { @MainActor [weak self] in
          self?.queueSave(recordType: ProfileRow.recordType, id: id, zoneID: zoneID)
        }
      },
      onRecordDeleted: { [weak self] id in
        Task { @MainActor [weak self] in
          self?.queueDeletion(recordType: ProfileRow.recordType, id: id, zoneID: zoneID)
        }
      })
  }
}

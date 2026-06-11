@preconcurrency import CloudKit
import Foundation
import OSLog
import os

// `CKSyncEngineDelegate` conformance for `SyncCoordinator`. The delegate runs
// on CKSyncEngine's internal executor; both entry points hop to `@MainActor`
// for all state access. The outbound batch-building helpers live in
// `SyncCoordinator+BatchBuilder.swift`.
extension SyncCoordinator: CKSyncEngineDelegate {

  // MARK: - Inbound Events

  nonisolated func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
    if case .fetchedRecordZoneChanges(let changes) = event {
      await handleFetchedRecordZoneChangesAsync(changes)
    } else if case .accountChange(let accountChange) = event {
      // Account-change handling now performs an `await` (GRDB read of
      // every profile id) so it can't be hosted inside a synchronous
      // `MainActor.run`. Hop directly to the main actor's async path.
      await handleAccountChangeOnMain(accountChange)
    } else {
      await MainActor.run {
        handleEventOnMain(event)
      }
    }
  }

  @MainActor
  private func handleAccountChangeOnMain(
    _ accountChange: CKSyncEngine.Event.AccountChange
  ) async {
    await handleAccountChange(accountChange)
  }

  @MainActor
  private func handleEventOnMain(_ event: CKSyncEngine.Event) {
    switch event {
    case .stateUpdate(let stateUpdate):
      saveStateSerialization(stateUpdate.stateSerialization)

    case .accountChange:
      // Routed through `handleAccountChangeOnMain` in `handleEvent`
      // because the sign-out path performs an async GRDB read.
      break

    case .fetchedDatabaseChanges(let changes):
      handleFetchedDatabaseChanges(changes)

    case .fetchedRecordZoneChanges:
      // Handled by handleFetchedRecordZoneChangesAsync
      break

    case .sentRecordZoneChanges(let sentChanges):
      handleSentRecordZoneChanges(sentChanges)

    case .willFetchChanges:
      beginFetchingChanges()

    case .didFetchChanges:
      endFetchingChanges()

    case .didFetchRecordZoneChanges(let event):
      // Fires even when the fetch returned zero changes, so the
      // "Checking iCloud…" → "No profiles in iCloud yet." transition
      // is possible for first-run users with an empty index zone.
      markZoneFetched(event.zoneID)

    case .sentDatabaseChanges, .willFetchRecordZoneChanges,
      .willSendChanges, .didSendChanges:
      break

    @unknown default:
      logger.debug("Unknown sync engine event")
    }
  }

  // MARK: - Outbound Batch Entry Point

  nonisolated func nextRecordZoneChangeBatch(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) async -> CKSyncEngine.RecordZoneChangeBatch? {
    await MainActor.run {
      nextRecordZoneChangeBatchOnMain(context, syncEngine: syncEngine)
    }
  }

  /// Bridges the engine's delegate call to the testable builder in
  /// `SyncCoordinator+BatchBuilder.swift`, passing the live engine state as the
  /// ``PendingChangeStore``.
  @MainActor
  private func nextRecordZoneChangeBatchOnMain(
    _ context: CKSyncEngine.SendChangesContext,
    syncEngine: CKSyncEngine
  ) -> CKSyncEngine.RecordZoneChangeBatch? {
    nextRecordZoneChangeBatch(scope: context.options.scope, state: syncEngine.state)
  }
}

import CloudKit
import Foundation
import GRDB

extension ProfileSession {
  /// Bundle of the three market-data services consumed by the CloudKit
  /// backend's `FullConversionService`. Lets `makeCloudKitBackend` take
  /// a single value instead of three separate parameters.
  struct CloudKitMarketDataServices {
    let exchangeRates: ExchangeRateService
    let stockPrices: StockPriceService
    let cryptoPrices: CryptoPriceService
  }

  /// Builds the CloudKit `BackendProvider` branch of `makeBackend`. Pulled
  /// out so `makeBackend` itself stays at SwiftLint's body-length policy
  /// while still doing the full registry/conversion-service/backend wiring
  /// inline (the construction order is load-bearing — see issue #102).
  static func makeCloudKitBackend(
    profile: Profile,
    syncCoordinator: SyncCoordinator?,
    marketData: CloudKitMarketDataServices,
    database: any DatabaseWriter,
    fallbackMetadataLookup: LateBoundCryptoMetadataLookup? = nil
  ) -> BackendProvider {
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-\(profile.id.uuidString)",
      ownerName: CKCurrentUserDefaultName)
    // Prefer the app-level shared registry when the coordinator was
    // constructed with one. All sessions on the same iCloud account
    // then share a single registry instance, so spam classifications
    // and discovered-token resolutions propagate without per-profile
    // duplication. Production ALWAYS lands here:
    // `MoolahApp.bootstrapSyncCoordinator` constructs the only
    // production `SyncCoordinator` with a non-nil
    // `sharedInstrumentRegistry`, so the fallback below is reached
    // exclusively by legacy callers (preview / tests) that didn't pass
    // a shared instance through `SyncCoordinator.init`.
    let registry: GRDBInstrumentRegistryRepository
    if let shared = syncCoordinator?.sharedInstrumentRegistry {
      registry = shared
    } else {
      // Preview / test fallback. The registry is built over a
      // profile-index database — never the per-profile `data.sqlite`,
      // which has no `instrument` table; instrument identity lives
      // solely on the profile-index registry. When a coordinator is
      // present its container manager's profile-index DB is reused;
      // otherwise a fresh in-memory profile-index DB stands in.
      //
      // The shared-registry path drives all remote-change fan-out via
      // `SyncCoordinator.makeInstrumentRemoteChangeFanOut` (installed
      // by `SyncCoordinator.init` on the profile-index handler), so
      // no extra wiring is needed here.
      registry = makeInstrumentRegistry(
        zoneID: zoneID, syncCoordinator: syncCoordinator)
    }
    // Bind the fallback `CryptoPriceService`'s late-bound metadata lookup to
    // this per-profile registry now that it exists. Restores equivalence with
    // the previous `cryptoRegistrations: { registry.allCryptoRegistrations() }`
    // wiring on the preview/legacy path, where the price service is built
    // before the registry. No-op on the shared path (the shared service
    // carries its own registry-backed lookup; the box is never consulted).
    fallbackMetadataLookup?.bind { id in try await registry.cryptoRegistration(byId: id) }
    // CloudKit profiles need full stock+crypto conversion support. Crypto
    // mapping / pricing status is self-resolved by `CryptoPriceService` via
    // its keyed `cryptoRegistration(byId:)` metadata plug (injected where the
    // shared service is constructed — `makeSharedInstrumentScope`, or rotated
    // in here on the fallback path), so the conversion layer no longer scans
    // the registry. See issue #102.
    //
    // `observeRates()` watches the rate-cache tables for change ticks.
    // The shared price services live on the profile-index DB, so the
    // observation must follow — watching the per-profile DB would
    // silently miss every cache write. Fall back to the per-profile DB
    // only for legacy callers that didn't pass a coordinator with
    // shared services (preview / tests).
    let rateObservationDatabase: any DatabaseWriter =
      syncCoordinator?.containerManager.profileIndexDatabase ?? database
    let conversionService = FullConversionService(
      exchangeRates: marketData.exchangeRates,
      stockPrices: marketData.stockPrices,
      cryptoPrices: marketData.cryptoPrices,
      database: rateObservationDatabase
    )
    let hooks = grdbRepoHooks(zoneID: zoneID, syncCoordinator: syncCoordinator)
    return CloudKitBackend(
      database: database,
      instrument: profile.instrument,
      profileLabel: profile.label,
      conversionService: conversionService,
      instrumentRegistry: registry,
      hooks: makeBackendHooks(hooks))
  }

  /// Fans the single shared `(changed, deleted)` closure pair across every
  /// per-record-type field on `CloudKitBackendHooks`.
  private static func makeBackendHooks(
    _ hooks: GRDBRepoHooks
  ) -> CloudKitBackend.CloudKitBackendHooks {
    CloudKitBackend.CloudKitBackendHooks(
      onCSVImportProfileChanged: hooks.changed,
      onCSVImportProfileDeleted: hooks.deleted,
      onImportRuleChanged: hooks.changed,
      onImportRuleDeleted: hooks.deleted,
      onAccountChanged: hooks.changed,
      onAccountDeleted: hooks.deleted,
      onAccountGroupChanged: hooks.changed,
      onAccountGroupDeleted: hooks.deleted,
      onInsightDismissalChanged: hooks.changed,
      onInsightDismissalDeleted: hooks.deleted,
      onCategoryChanged: hooks.changed,
      onCategoryDeleted: hooks.deleted,
      onTransferSuggestionChanged: hooks.changed,
      onTransferSuggestionDeleted: hooks.deleted,
      onEarmarkChanged: hooks.changed,
      onEarmarkDeleted: hooks.deleted,
      onEarmarkBudgetItemChanged: hooks.changed,
      onEarmarkBudgetItemDeleted: hooks.deleted,
      onInvestmentChanged: hooks.changed,
      onInvestmentDeleted: hooks.deleted,
      onTransactionChanged: hooks.changed,
      onTransactionDeleted: hooks.deleted,
      onTransactionLegChanged: hooks.changed,
      onTransactionLegDeleted: hooks.deleted)
  }

  /// Bundle of the change/delete closures the GRDB repos call on each
  /// successful local mutation. Both record types share the same shape
  /// (`(recordType, id) -> queueSave/queueDeletion`), so a single pair
  /// covers them all — keeps the wiring uniform and small.
  private struct GRDBRepoHooks {
    let changed: @Sendable (String, UUID) -> Void
    let deleted: @Sendable (String, UUID) -> Void
  }

  /// Builds the GRDB-repo hook closures that fan local mutations out to
  /// the sync coordinator's queue. Returns no-op closures when no
  /// coordinator is wired (preview / test backends).
  private static func grdbRepoHooks(
    zoneID: CKRecordZone.ID, syncCoordinator: SyncCoordinator?
  ) -> GRDBRepoHooks {
    GRDBRepoHooks(
      changed: { [weak syncCoordinator] recordType, id in
        Task { @MainActor [weak syncCoordinator] in
          syncCoordinator?.queueSave(recordType: recordType, id: id, zoneID: zoneID)
        }
      },
      deleted: { [weak syncCoordinator] recordType, id in
        Task { @MainActor [weak syncCoordinator] in
          syncCoordinator?.queueDeletion(recordType: recordType, id: id, zoneID: zoneID)
        }
      })
  }

  /// Builds the preview/test-only `GRDBInstrumentRegistryRepository`,
  /// wiring its mutation hooks to the sync coordinator's per-zone queue
  /// helpers.
  ///
  /// The registry is backed by a profile-index database, never the
  /// per-profile `data.sqlite` (which has no `instrument` table): the
  /// coordinator's container-manager profile-index DB when a coordinator
  /// is present, otherwise a fresh in-memory profile-index DB. This
  /// branch is unreachable in production — see `makeCloudKitBackend` —
  /// so trapping on the (test-harness-only) in-memory open failure
  /// mirrors `PreviewBackend`'s precedent and never affects shipping
  /// code.
  private static func makeInstrumentRegistry(
    zoneID: CKRecordZone.ID,
    syncCoordinator: SyncCoordinator?
  ) -> GRDBInstrumentRegistryRepository {
    let database: any DatabaseWriter
    if let containerManager = syncCoordinator?.containerManager {
      database = containerManager.profileIndexDatabase
    } else {
      // In-memory ProfileIndexDatabase.openInMemory() cannot fail (no
      // filesystem path); this branch is test-harness-only (no
      // coordinator) and never runs in production — see the doc comment.
      // swiftlint:disable:next force_try
      database = try! ProfileIndexDatabase.openInMemory()
    }
    return GRDBInstrumentRegistryRepository(
      database: database,
      onRecordChanged: { [weak syncCoordinator] recordName in
        // Registry callbacks may run off MainActor; hop onto MainActor to
        // reach the actor-isolated SyncCoordinator.queueSave(_:zoneID:).
        Task { @MainActor [weak syncCoordinator] in
          syncCoordinator?.queueSave(recordName: recordName, zoneID: zoneID)
        }
      },
      onRecordDeleted: { [weak syncCoordinator] recordName in
        Task { @MainActor [weak syncCoordinator] in
          syncCoordinator?.queueDeletion(recordName: recordName, zoneID: zoneID)
        }
      }
    )
  }

  // `wireInstrumentRemoteChangeFanOut` is intentionally absent here:
  // the shared registry on the profile-index zone drives every
  // InstrumentRecord remote-change fan-out via
  // `SyncCoordinator.makeInstrumentRemoteChangeFanOut`.
}

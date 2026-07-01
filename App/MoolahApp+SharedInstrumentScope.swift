// App/MoolahApp+SharedInstrumentScope.swift

import CloudKit
import Foundation
import GRDB

/// Boot-time setup for the app-level shared instrument registry and
/// the coordinated `MarketDataServices`.
extension MoolahApp {

  /// Boot-time sync setup: shared registry + market-data services
  /// pointed at the profile-index DB, plus the constructed
  /// `SyncCoordinator` with the registry's sync hooks rotated in.
  static func bootstrapSyncCoordinator(setup: ContainerSetup) -> SyncCoordinator {
    let networking = NetworkingServices()
    // Build the resolver first so the shared registry can apply `alias_of`
    // on incoming instrument records (design §3.5). Its observation task is
    // wired after the coordinator exists so it can be stored on the coordinator
    // and cancelled by stop().
    let canonicalResolver = CanonicalInstrumentResolver()
    let scope = makeSharedInstrumentScope(
      setup: setup, networking: networking, canonicalResolver: canonicalResolver)
    // App-level store of the registry data — every per-session
    // `CryptoTokenStore` proxies its `registrations` /
    // `instruments` / `providerMappings` / `registrationsVersion`
    // reads through this single instance so a mutation on one
    // session's view is observed by every other session's UI
    // without per-session re-load. The store subscribes to
    // `registry.observeChanges()` for its lifetime so remote-
    // arriving CKSyncEngine applies fan out automatically.
    let registryStore = SharedRegistryStore(registry: scope.registry)
    let coordinator = SyncCoordinator(
      containerManager: setup.manager,
      sharedInstrumentRegistry: scope.registry,
      sharedMarketData: scope.marketData,
      sharedRegistryStore: registryStore,
      sharedNetworking: networking,
      sharedCanonicalResolver: canonicalResolver)
    coordinator.startCanonicalResolverObservation(
      registry: scope.registry, changes: scope.registry.observeChanges())
    attachSharedInstrumentRegistrySyncHooks(
      registry: scope.registry, coordinator: coordinator)
    return coordinator
  }

  /// Constructs the app-level shared `GRDBInstrumentRegistryRepository`
  /// pointed at the profile-index DB, wired with `canonicalResolver` so the
  /// apply path marks incoming retired cross-chain instrument rows `alias_of`
  /// their canonical id (design §3.5). Sync hooks are no-ops at construction
  /// time and rotated in via `attachSharedInstrumentRegistrySyncHooks` once the
  /// `SyncCoordinator` exists (chicken-and-egg: the coordinator's init takes
  /// the registry, so the registry can't capture the coordinator at its own init).
  private static func makeSharedInstrumentRegistry(
    database: any DatabaseWriter,
    canonicalResolver: CanonicalInstrumentResolver
  ) -> GRDBInstrumentRegistryRepository {
    GRDBInstrumentRegistryRepository(database: database, canonicalResolver: canonicalResolver)
  }

  /// Bundles the shared registry + market-data services, both pointed
  /// at the profile-index DB. Tuple shape keeps `MoolahApp.init` short.
  static func makeSharedInstrumentScope(
    setup: ContainerSetup,
    networking: NetworkingServices,
    canonicalResolver: CanonicalInstrumentResolver
  ) -> (
    registry: GRDBInstrumentRegistryRepository,
    marketData: ProfileSession.MarketDataServices
  ) {
    let database = setup.manager.profileIndexDatabase
    // Build the registry first so its indexed `cryptoRegistration(byId:)`
    // point lookup can be injected as the `CryptoPriceService` metadata plug.
    // The conversion layer then self-resolves crypto mappings / pricing status
    // through the price service instead of scanning the registry.
    let registry = makeSharedInstrumentRegistry(
      database: database, canonicalResolver: canonicalResolver)
    return (
      registry: registry,
      marketData: ProfileSession.makeMarketDataServices(
        database: database,
        networking: networking,
        cryptoMetadataLookup: { id in try await registry.cryptoRegistration(byId: id) })
    )
  }

  /// Wires the shared registry's mutation hooks to the coordinator's
  /// `queueSave` / `queueDeletion` against the profile-index zone.
  /// Called immediately after `SyncCoordinator.init`, which takes the
  /// registry as a constructor argument.
  ///
  /// The `Task { @MainActor in … }` hop matches the per-profile
  /// pattern in `ProfileSession+CloudKitBackendBuild.makeInstrumentRegistry`:
  /// registry callbacks fire on the GRDB serial executor
  /// (off-MainActor) and `SyncCoordinator.queueSave/Deletion` is
  /// `@MainActor`-isolated.
  static func attachSharedInstrumentRegistrySyncHooks(
    registry: GRDBInstrumentRegistryRepository,
    coordinator: SyncCoordinator
  ) {
    let zoneID = CKRecordZone.ID(
      zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
    registry.attachSyncHooks(
      onRecordChanged: { [weak coordinator] recordName in
        Task { @MainActor [weak coordinator] in
          coordinator?.queueSave(recordName: recordName, zoneID: zoneID)
        }
      },
      onRecordDeleted: { [weak coordinator] recordName in
        Task { @MainActor [weak coordinator] in
          coordinator?.queueDeletion(recordName: recordName, zoneID: zoneID)
        }
      })
  }
}

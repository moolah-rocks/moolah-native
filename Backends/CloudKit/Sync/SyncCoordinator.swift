@preconcurrency import CloudKit
import Foundation
import OSLog
import os

/// Unified sync coordinator that owns a single `CKSyncEngine` for the entire app.
///
/// Routes events by zone ID to `ProfileDataSyncHandler` or `ProfileIndexSyncHandler`.
/// Everything runs on `@MainActor` — no concurrency races by construction.
///
/// Zone routing:
/// - `profile-index` → `ProfileIndexSyncHandler`
/// - `profile-<uuid>` → `ProfileDataSyncHandler` (via `ProfileContainerManager`)
///
/// The class body here is intentionally small: nested types, stored state, observers,
/// handler access, refetch scheduling, and state-file persistence. Lifecycle, zone
/// handling, backfill, record-change application, and the `CKSyncEngineDelegate`
/// conformance live in sibling extension files under `Backends/CloudKit/Sync/`.
@Observable
@MainActor
final class SyncCoordinator {

  // MARK: - Zone Parsing

  enum ZoneType: Equatable {
    case profileIndex
    case profileData(UUID)
    case unknown
  }

  nonisolated static func parseZone(_ zoneID: CKRecordZone.ID) -> ZoneType {
    let name = zoneID.zoneName
    if name == "profile-index" {
      return .profileIndex
    }
    if name.hasPrefix("profile-") {
      let suffix = String(name.dropFirst("profile-".count))
      if let uuid = UUID(uuidString: suffix) {
        return .profileData(uuid)
      }
    }
    return .unknown
  }

  /// Result of preparing a `CKSyncEngine` off the main actor — returned by
  /// `prepareEngine(stateFileURL:delegate:)` and consumed by `completeStart`.
  /// `@unchecked Sendable` because `CKSyncEngine` isn't declared `Sendable` by
  /// CloudKit, but we only transfer ownership one-way (prepare-thread → main
  /// actor) with no concurrent readers, so the Task.value happens-before edge
  /// makes it safe. Keep this struct to value types only.
  ///
  /// Authorized carve-out: see `guides/CONCURRENCY_GUIDE.md` §2 "False
  /// Positives to Avoid", Carve-out 2 (one-way ownership transfer).
  struct PreparedEngine: @unchecked Sendable {
    let engine: CKSyncEngine
    let isFirstLaunch: Bool
  }

  // MARK: - Index Observer

  private struct IndexObserver {
    let id: UUID
    let callback: @MainActor () -> Void
  }

  private var indexObservers: [IndexObserver] = []

  func addIndexObserver(_ callback: @escaping @MainActor () -> Void) -> UUID {
    let id = UUID()
    indexObservers.append(IndexObserver(id: id, callback: callback))
    return id
  }

  func removeIndexObserver(_ id: UUID) {
    indexObservers.removeAll { $0.id == id }
  }

  /// Notify index observers. Exposed for testing.
  func notifyIndexObservers() {
    for observer in indexObservers {
      observer.callback()
    }
  }

  // MARK: - State

  let stateFileURL = URL.moolahScopedApplicationSupport
    .appending(path: "Moolah-v2-sync.syncstate")

  let containerManager: ProfileContainerManager
  /// `nonisolated` because `ProfileIndexSyncHandler` is `Sendable` and the
  /// reference is `let`. Lets the off-main `applyFetchedIndexChanges` path
  /// read the handler without a MainActor hop.
  nonisolated let profileIndexHandler: ProfileIndexSyncHandler

  /// The app-level shared `GRDBInstrumentRegistryRepository`. Exposed
  /// so `ProfileSession.makeCloudKitBackend` can hand the same instance
  /// to every session's `CloudKitBackend`. Settings views, the search
  /// service, and the conversion service all read from this shared
  /// instance rather than per-profile registries.
  ///
  /// `nil` for callers (e.g. tests) that don't pass a shared
  /// registry — those use the per-profile registry path.
  nonisolated let sharedInstrumentRegistry: GRDBInstrumentRegistryRepository?

  /// App-level shared `MarketDataServices` (exchange / stock / crypto
  /// price services + Yahoo client + CoinGecko key) pointed at the
  /// profile-index DB. When wired, every profile session reads through
  /// these instead of constructing per-profile copies, so price-cache
  /// writes land in the same DB and feed the `notifyRateCacheChange`
  /// observation. `nil` for tests that don't pass shared services.
  nonisolated let sharedMarketData: ProfileSession.MarketDataServices?

  /// App-level shared `NetworkingServices` instance. Vends per-host
  /// `RateLimitedHTTPClient`s so a 429 from one caller cools down every
  /// caller of that host. `nil` for preview / test callers that don't
  /// pass shared services.
  nonisolated let sharedNetworking: NetworkingServices?

  /// App-level shared `SharedRegistryStore` — owns the registry data
  /// (`registrations`, `instruments`, `providerMappings`,
  /// `registrationsVersion`) and subscribes to the registry's
  /// `observeChanges()` so a mutation through any session (or a
  /// remote-arriving CKSyncEngine apply) updates every session's
  /// view on the next read. Per-session `CryptoTokenStore` instances
  /// hold a reference and proxy data reads to this store; per-
  /// session UI state (`error`, `isLoading`) stays on the per-session
  /// store so a transient failure in one session doesn't leak onto
  /// every Settings screen. `nil` for callers (preview /
  /// tests) that don't construct a shared store.
  ///
  /// Not `nonisolated`: `SharedRegistryStore` is `@MainActor
  /// @Observable` and reading it from a non-`@MainActor` context
  /// would race the observation infrastructure. `SyncCoordinator`
  /// itself is `@MainActor`, so all access is already isolated and
  /// the keyword is unnecessary.
  let sharedRegistryStore: SharedRegistryStore?

  // Cross-file-access note: members below this MARK that sibling extension
  // files (Lifecycle / Zones / Backfill / RecordChanges / Delegate) touch are
  // `internal` rather than `private`. Swift does not treat extensions in
  // separate files as part of the same scope, so `private` would make them
  // unreachable. None is reachable outside the module.

  /// User defaults used to persist per-profile "backfill scan complete" flags so the
  /// scan runs at most once per profile across app launches. Injected for testing.
  let userDefaults: UserDefaults

  /// Key prefix for the per-profile backfill-scan-completed flag. The full key is
  /// `"\(backfillScanCompleteKeyPrefix).\(profileId.uuidString)"`.
  static let backfillScanCompleteKeyPrefix = "com.moolah.sync.backfillScanComplete"

  /// Observable sync progress consumed by the sidebar footer and the
  /// `.heroDownloading` Welcome arm. Always non-nil; SyncCoordinator
  /// drives transitions from its existing CKSyncEngine event hooks.
  let progress: SyncProgress

  let logger = Logger(subsystem: "com.moolah.app", category: "SyncCoordinator")

  var syncEngine: CKSyncEngine?

  var isRunning = false

  /// Tracks whether this coordinator started without saved state (first launch or migration).
  /// Used to guard against the synthetic `.signIn` event.
  var isFirstLaunch = false

  /// Observable iCloud account availability. `.unknown` while a probe is
  /// outstanding; see `handleAccountChange` in `SyncCoordinator+Zones.swift`
  /// for ongoing updates, and `completeStart` in `+Lifecycle.swift` for the
  /// initial probe. Views bind via `ProfileStore.iCloudAvailability`.
  var iCloudAvailability: ICloudAvailability = .unknown

  /// Captured at init from `CloudKitAuthProvider.isCloudKitAvailable` (or a
  /// test override). `false` short-circuits the initial probe in
  /// `completeStart` because the build has no iCloud entitlements.
  let isCloudKitAvailable: Bool

  /// Maps `CKAccountStatus` to ``ICloudAvailability``.
  /// `.couldNotDetermine` and thrown errors are treated as `.unknown`
  /// (transient) per design spec §6.1.
  nonisolated static func mapAccountStatus(
    _ status: CKAccountStatus
  ) -> ICloudAvailability {
    switch status {
    case .available:
      return .available
    case .noAccount:
      return .unavailable(reason: .notSignedIn)
    case .restricted:
      return .unavailable(reason: .restricted)
    case .temporarilyUnavailable:
      return .unavailable(reason: .temporarilyUnavailable)
    case .couldNotDetermine:
      return .unknown
    @unknown default:
      return .unknown
    }
  }

  /// True while CKSyncEngine is fetching changes (between willFetchChanges and didFetchChanges).
  var isFetchingChanges = false

  /// True when iCloud storage is full and sync uploads are failing.
  /// Cleared when a send cycle completes without quota errors.
  var isQuotaExceeded = false

  /// Whether the profile-index zone had changes during the current fetch session.
  var fetchSessionIndexChanged = false

  /// True once the `profile-index` zone has been fetched (even empty-handed)
  /// at least once since the last `start()`. `WelcomeView` uses this to
  /// swap "Checking iCloud…" for "No profiles in iCloud yet." once we
  /// know the answer. Must NOT flip on fetches that only touched
  /// `profile-data` zones. See design spec §6.2.
  /// Writable-internal because `+Lifecycle` (separate file) resets it
  /// inside `stop()` and flips it inside `endFetchingChanges()`.
  var profileIndexFetchedAtLeastOnce: Bool = false

  /// Per-session flag — set true inside the delegate zone-fetch path
  /// when the `profile-index` zone ID is observed, regardless of whether
  /// records were applied. Flushed into `profileIndexFetchedAtLeastOnce`
  /// inside `endFetchingChanges()`. Reset inside `beginFetchingChanges()`.
  var fetchSessionTouchedIndexZone = false

  /// Cached profile data handlers, keyed by profile UUID.
  var dataHandlers: [UUID: ProfileDataSyncHandler] = [:]

  /// Per-profile cache of auto-constructed GRDB repository bundles, keyed by
  /// profile UUID. Populated on first access in
  /// `resolveGRDBRepositories(for:)` and retained so subsequent calls to
  /// `handlerForProfileZone` reuse the same bundle without hitting the
  /// database layer again. See `ProfileGRDBRepositories`.
  var cachedGRDBRepositories: [UUID: ProfileGRDBRepositories] = [:]

  /// Zones with pending zone creation — records in these zones are skipped in nextRecordZoneChangeBatch.
  var pendingZoneCreation: [CKRecordZone.ID: [CKSyncEngine.PendingRecordZoneChange]] = [:]

  /// Active zone creation tasks, keyed by zone ID.
  var zoneCreationTasks: [CKRecordZone.ID: Task<Void, Never>] = [:]

  /// The zone setup task (creates profile-index zone on start).
  var zoneSetupTask: Task<Void, Never>?

  /// Task that runs `CKSyncEngine.init` off the main actor. Held so it can be
  /// awaited/cancelled from `stop()`.
  var startTask: Task<Void, Never>?

  /// Task spawned by `startAfter(profileIndexMigration:)` that waits for
  /// any launch-time profile-index migration to commit before invoking
  /// `start()`. Held so `stop()` can cancel it if the app tears the
  /// coordinator down before the migration finishes.
  var launchTask: Task<Void, Never>?

  /// Task for coalescing re-fetch requests after save failures.
  var refetchTask: Task<Void, Never>?

  /// Last-resort periodic retry scheduled after the short-retry budget is exhausted.
  /// Fires every `longRetryInterval`, resets the short-retry counter, and re-triggers
  /// a fetch so persistent failures don't leave local data silently incomplete.
  var longRetryTask: Task<Void, Never>?

  /// Initial `CKContainer.accountStatus()` probe kicked off from
  /// `completeStart`. Held so `stop()` can cancel it.
  var availabilityProbeTask: Task<Void, Never>?

  /// Scene-active fetch handle. `scheduleFetchChanges` cancels-and-replaces; `stop()` clears it.
  var fetchChangesTask: Task<Void, Never>?

  /// Number of consecutive re-fetch attempts scheduled after a save failure.
  /// Reset to zero whenever a fetched-record-zone-changes batch applies successfully.
  /// Exposed for testing.
  var refetchAttempts = 0

  /// `true` while a last-resort periodic retry is pending. Exposed for testing.
  var hasPendingLongRetry: Bool { longRetryTask != nil }

  // (Re-fetch backoff constants and `refetchBackoff(forAttempt:)` live in
  // `SyncCoordinator+Lifecycle.swift` with the rest of the lifecycle
  // wiring.)

  // MARK: - Init

  init(
    containerManager: ProfileContainerManager,
    userDefaults: UserDefaults = .moolahShared,
    isCloudKitAvailable: Bool = CloudKitAuthProvider.isCloudKitAvailable,
    sharedInstrumentRegistry: GRDBInstrumentRegistryRepository? = nil,
    sharedMarketData: ProfileSession.MarketDataServices? = nil,
    sharedRegistryStore: SharedRegistryStore? = nil,
    sharedNetworking: NetworkingServices? = nil
  ) {
    self.containerManager = containerManager
    self.userDefaults = userDefaults
    self.progress = SyncProgress(userDefaults: userDefaults)
    self.sharedInstrumentRegistry = sharedInstrumentRegistry
    self.sharedMarketData = sharedMarketData
    self.sharedRegistryStore = sharedRegistryStore
    self.sharedNetworking = sharedNetworking
    self.profileIndexHandler = ProfileIndexSyncHandler(
      repository: containerManager.profileIndexRepository,
      instrumentRepository: sharedInstrumentRegistry,
      onInstrumentRemoteChange: Self.makeInstrumentRemoteChangeFanOut(
        registry: sharedInstrumentRegistry))
    self.isCloudKitAvailable = isCloudKitAvailable
    if !isCloudKitAvailable {
      applyICloudAvailability(.unavailable(reason: .entitlementsMissing))
    }
    // SAFETY: wireProfileIndexHooks() must remain the last statement in init.
    // The closures it installs capture `[weak self]` and depend on every
    // stored property of SyncCoordinator being assigned.
    wireProfileIndexHooks()
  }

  /// Builds the `@Sendable` closure that the profile-index handler
  /// fires after applying remote `InstrumentRecord` rows. Hops to
  /// `@MainActor` to invoke `notifyExternalChange()` on the registry;
  /// `nil` registry → no-op closure.
  private static func makeInstrumentRemoteChangeFanOut(
    registry: GRDBInstrumentRegistryRepository?
  ) -> @Sendable () -> Void {
    guard let registry else { return {} }
    return { [weak registry] in
      Task { @MainActor [weak registry] in
        registry?.notifyExternalChange()
      }
    }
  }

  // MARK: - Fetch-Session Book-keeping
  // (Begin/end live on `+Lifecycle`; the isFetchingChanges flag is mutated there
  // and by `+Zones` on sign-out.)

  // MARK: - Handler Access
  // (Lazy `ProfileDataSyncHandler` creation and the per-profile
  // instrument-change callback registry live on `+HandlerAccess`.)

  // MARK: - State Persistence
  // (Load happens off-actor in `prepareEngine` on `+Lifecycle`; the
  // write / delete paths live on `+StatePersistence`.)
}

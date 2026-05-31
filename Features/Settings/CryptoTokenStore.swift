// Features/Settings/CryptoTokenStore.swift
import Foundation
import OSLog

/// Per-session façade over the app-level `SharedRegistryStore`. Owns
/// the per-session UI state (`error`, `isLoading`, the
/// `onRegistrationsChanged` callback for cross-store side effects) and
/// the per-session keychain reads. Registry data
/// (`registrations`, `instruments`, `providerMappings`,
/// `registrationsVersion`) lives on the shared store so a mutation
/// from any session is immediately visible to every session's UI.
///
/// **Two construction shapes.** Production passes a `sharedStore`
/// reference (production wires it from
/// `SyncCoordinator.sharedRegistryStore`); legacy preview / test
/// callers omit it and the store falls back to local storage —
/// equivalent to the pre-shared-registry behaviour.
@MainActor
@Observable
final class CryptoTokenStore {

  /// Shared backing store, if wired. When non-nil, every data read
  /// proxies through it so cross-session mutations are observed
  /// transparently. When nil (preview / legacy tests), the store
  /// keeps its own local copies and behaves as before.
  private let sharedStore: SharedRegistryStore?

  // MARK: - Local fallback storage (preview / legacy tests)

  private var localRegistrations: [CryptoRegistration] = []
  private var localInstruments: [Instrument] = []
  private var localProviderMappings: [String: CryptoProviderMapping] = [:]
  private var localRegistrationsVersion: Int = 0

  // MARK: - Proxied data

  var registrations: [CryptoRegistration] {
    sharedStore?.registrations ?? localRegistrations
  }
  var instruments: [Instrument] {
    sharedStore?.instruments ?? localInstruments
  }
  var providerMappings: [String: CryptoProviderMapping] {
    sharedStore?.providerMappings ?? localProviderMappings
  }
  /// Monotonic version bumped after every successful registry mutation
  /// (`setStatus`, `removeRegistration`). Views that derive per-account
  /// valued positions pin a `.task(id:)` against this so a `.spam` flip
  /// in preferences re-fires the per-row valuator without the user
  /// having to navigate away. Issue #790.
  var registrationsVersion: Int {
    sharedStore?.registrationsVersion ?? localRegistrationsVersion
  }

  // MARK: - Per-session UI state

  private(set) var isLoading = false

  private(set) var error: String?

  /// Fired after a successful registry mutation that may change a
  /// registration's `pricingStatus` or remove a row. Wired by
  /// `ProfileSession` to drive the per-store re-aggregation that
  /// otherwise wouldn't observe registry changes — e.g. so the
  /// `InvestmentStore`'s `valuedPositions` drops a freshly-marked
  /// `.spam` token from the account's position list. Issue #790.
  var onRegistrationsChanged: (@MainActor () -> Void)?

  private let registry: any InstrumentRegistryRepository
  private let cryptoPriceService: CryptoPriceService
  private let conversionService: any InstrumentConversionService
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "CryptoTokenStore")

  private let apiKeyStore: KeychainStore

  /// Keychain entry for the Alchemy API key, used by the crypto-wallet
  /// auto-import. Service / account strings are pinned to the values
  /// `ProfileSession+CryptoSync` reads on the sync side so reads pick
  /// up whatever the settings UI writes here. Production wires this
  /// to the iCloud-synced keychain (`synchronizable: true`); tests
  /// inject a
  /// non-synced `KeychainStore` since the test runner cannot write to
  /// the synced keychain in CI.
  private let alchemyKeyStore: KeychainStore

  /// Subscription to the registry's change stream so per-session side
  /// effects fire when ANY session (including this one) mutates the
  /// shared registry. The `onRegistrationsChanged` callback drives
  /// `InvestmentStore` revaluation; cross-session conversion-cache
  /// invalidation also fires here.
  private var observationTask: Task<Void, Never>?

  /// Designated initialiser — accepts the keychain stores explicitly.
  /// Production constructs both stores against the iCloud-synced
  /// keychain at the canonical service / account ids (see the
  /// `convenience init` below). Tests inject non-synchronisable
  /// instances since the macOS test runner cannot write to the synced
  /// keychain. Internal access (not `private`) so tests in the same
  /// module can reach it; the production convenience initialiser stays
  /// the public surface.
  init(
    registry: any InstrumentRegistryRepository,
    cryptoPriceService: CryptoPriceService,
    conversionService: any InstrumentConversionService,
    apiKeyStore: KeychainStore,
    alchemyKeyStore: KeychainStore,
    sharedStore: SharedRegistryStore? = nil
  ) {
    self.registry = registry
    self.cryptoPriceService = cryptoPriceService
    self.conversionService = conversionService
    self.apiKeyStore = apiKeyStore
    self.alchemyKeyStore = alchemyKeyStore
    self.sharedStore = sharedStore

    let stream = registry.observeChanges()
    self.observationTask = Task { @MainActor [weak self] in
      for await _ in stream {
        self?.handleRegistryChangeTick()
      }
    }
  }

  deinit {
    // Swift 6 nonisolated deinit; the task is owned by the per-
    // session `CryptoTokenStore` instance, which `ProfileSession`
    // (`@MainActor`) holds as a stored let property. The only
    // deallocation path is when `ProfileSession` releases the last
    // strong reference, and that release happens on the main actor
    // (`SessionManager`'s teardown is `@MainActor`-isolated). The
    // assumption therefore holds; a future refactor that introduces
    // a non-`@MainActor` owner traps immediately instead of racing
    // the observation infrastructure.
    MainActor.assumeIsolated {
      observationTask?.cancel()
    }
  }

  /// Production convenience initialiser — wires both keychain stores
  /// to the iCloud-synced keychain at the canonical service / account
  /// ids. The shape mirrors `ProfileSession.resolveAlchemyApiKey()`'s
  /// keychain coordinates so a write from settings is picked up by
  /// the next sync cycle without further plumbing.
  convenience init(
    registry: any InstrumentRegistryRepository,
    cryptoPriceService: CryptoPriceService,
    conversionService: any InstrumentConversionService,
    sharedStore: SharedRegistryStore? = nil
  ) {
    self.init(
      registry: registry,
      cryptoPriceService: cryptoPriceService,
      conversionService: conversionService,
      apiKeyStore: KeychainStore(
        service: KeychainServices.apiKeys, account: "coingecko", synchronizable: true),
      alchemyKeyStore: KeychainStore(
        service: KeychainServices.apiKeys, account: "alchemy", synchronizable: true),
      sharedStore: sharedStore)
  }

  // MARK: - Filtered registrations

  /// Subset of `registrations` with `pricingStatus == .unpriced`. Drives
  /// the Discovered Tokens inbox row count + the sidebar badge.
  var unpricedRegistrations: [CryptoRegistration] {
    registrations.filter { $0.pricingStatus == .unpriced }
  }

  /// Convenience for the sidebar / preferences badge — number of
  /// unresolved tokens awaiting user attention.
  var unpricedCount: Int { unpricedRegistrations.count }

  /// Subset of `registrations` with `pricingStatus == .spam`. Drives the
  /// Spam tokens management list.
  var spamRegistrations: [CryptoRegistration] {
    registrations.filter { $0.pricingStatus == .spam }
  }

  /// The instruments of all `.spam`-flagged registrations.
  ///
  /// Derived from `spamRegistrations`; updates automatically whenever
  /// `registrations` changes. Returns an empty set when no registrations
  /// carry `.spam` status.
  var spamInstruments: Set<Instrument> {
    Set(spamRegistrations.map(\.instrument))
  }

  func loadRegistrations() async {
    isLoading = true
    defer { isLoading = false }
    if let sharedStore {
      await sharedStore.loadRegistrations()
      error = nil
      return
    }
    do {
      let loaded = try await registry.allCryptoRegistrations()
      localRegistrations = loaded
      localInstruments = loaded.map(\.instrument)
      localProviderMappings = Dictionary(
        loaded.map { ($0.mapping.instrumentId, $0.mapping) },
        uniquingKeysWith: { _, last in last }
      )
      error = nil
    } catch is CancellationError {
      // `.task`-driven load cancelled by view teardown — never surface;
      // a re-mount issues its own `loadRegistrations`.
      return
    } catch {
      logger.error(
        "Failed to load crypto registrations: \(error, privacy: .public)")
      self.error = error.localizedDescription
    }
  }

  func removeRegistration(_ registration: CryptoRegistration) async {
    do {
      if let sharedStore {
        try await sharedStore.removeRegistration(registration)
      } else {
        try await registry.remove(id: registration.id)
        localRegistrations.removeAll { $0.id == registration.id }
        localInstruments.removeAll { $0.id == registration.id }
        localProviderMappings.removeValue(forKey: registration.id)
        localRegistrationsVersion &+= 1
      }
      // Per-session side effect: purge this session's price cache
      // for the removed instrument so a future conversion refetches
      // rather than serving a now-orphan cached price.
      await cryptoPriceService.purgeCache(instrumentId: registration.id)
      error = nil
      // `onRegistrationsChanged` is fired centrally by
      // `handleRegistryChangeTick` on the next observation tick — the
      // local mutation we just performed will trigger that tick via
      // the registry's `notifySubscribers`. Firing it here too would
      // double-invoke `InvestmentStore.revaluateLoadedPositions`.
    } catch {
      logger.error("Failed to remove registration: \(error, privacy: .public)")
      self.error = error.localizedDescription
    }
  }

  func removeInstrument(_ instrument: Instrument) async {
    guard let registration = registrations.first(where: { $0.instrument.id == instrument.id })
    else { return }
    await removeRegistration(registration)
  }

  /// Persists a new `pricingStatus` for an existing registration and
  /// synchronously invalidates this session's cached conversion derived
  /// from the instrument so the next aggregation reads fresh data. Used
  /// by the Discovered Tokens inbox + Spam tokens management UI to flip
  /// a registration between `.priced` / `.unpriced` / `.spam`.
  ///
  /// On failure the registry write rolls back and `error` is set.
  /// Cache invalidation only runs after the registry write succeeds —
  /// we never invalidate on behalf of a write that didn't happen.
  func setStatus(
    _ status: TokenPricingStatus,
    for registration: CryptoRegistration
  ) async {
    var updated = registration
    updated.pricingStatus = status
    do {
      if let sharedStore {
        try await sharedStore.setStatus(status, for: registration)
      } else {
        try await registry.update(updated)
        if let index = localRegistrations.firstIndex(where: { $0.id == registration.id }) {
          localRegistrations[index] = updated
        }
        localRegistrationsVersion &+= 1
      }
      // Per-session conversion-cache invalidation. Fires on every
      // path so a mutation through the local fallback OR the shared
      // store flushes this session's `FullConversionService` cache.
      await conversionService.invalidateCache(for: registration.instrument)
      error = nil
      // `onRegistrationsChanged` fires from `handleRegistryChangeTick`
      // on the upcoming registry tick (triggered by the mutation
      // above). Firing here too would double-invoke
      // `InvestmentStore.revaluateLoadedPositions`.
    } catch {
      logger.error("Failed to set pricing status: \(error, privacy: .public)")
      self.error = error.localizedDescription
    }
  }

  // MARK: - Cross-session change tick

  /// Fired by the `observeChanges()` subscription on every registry
  /// mutation — local OR remote-arriving via CKSyncEngine. The shared
  /// store reloads its data fields automatically; this hook fires
  /// per-session side effects (cross-store revaluation, cache
  /// invalidation) so a mutation through profile A ripples through
  /// profile B's UI within one cycle.
  ///
  /// The hook intentionally does NOT invalidate per-instrument
  /// conversion caches here — the cache is keyed by date pairs that
  /// change every conversion call, so over-invalidating on every
  /// remote tick would thrash. Conversion-cache invalidation lives
  /// inside `setStatus(_:for:)` for the local-mutation path; the
  /// next conversion call after a remote-arriving status change
  /// re-reads the registry on cache miss.
  private func handleRegistryChangeTick() {
    onRegistrationsChanged?()
  }

  // MARK: - CoinGecko API Key

  var hasApiKey: Bool {
    do {
      return try apiKeyStore.restoreString() != nil
    } catch {
      logger.error("keychain read failed: \(error.localizedDescription)")
      return false
    }
  }

  func saveApiKey(_ key: String) {
    do {
      try apiKeyStore.saveString(key)
      self.error = nil
    } catch {
      logger.error(
        "CoinGecko API key save failed: \(error.localizedDescription, privacy: .public)")
      self.error = "Failed to save API key: \(error.localizedDescription)"
    }
  }

  func clearApiKey() {
    apiKeyStore.clear()
  }

  // MARK: - Alchemy API Key
  //
  // The Alchemy key drives the wallet auto-import.
  // `ProfileSession.resolveAlchemyApiKey()` reads from the same
  // `(service, account)` keychain entry, so a write here is picked up
  // by the next sync cycle without further plumbing. The key value
  // itself is never logged; failure paths log only the wrapping
  // `error.localizedDescription` (which carries the underlying
  // `OSStatus` via `KeychainError`).

  /// `true` when an Alchemy API key is configured in the synced
  /// Keychain. Read on every UI render to drive the status badge —
  /// the keychain read is cheap (~µs) and consulting a cached `Bool`
  /// would require an explicit invalidation hook on save / clear.
  var hasAlchemyApiKey: Bool {
    do {
      return try alchemyKeyStore.restoreString() != nil
    } catch {
      logger.error("keychain read failed: \(error.localizedDescription)")
      return false
    }
  }

  /// Persists the Alchemy API key to the synced Keychain. Sets
  /// `error` (without logging the key) on failure.
  func saveAlchemyApiKey(_ key: String) {
    do {
      try alchemyKeyStore.saveString(key)
      self.error = nil
    } catch {
      logger.error(
        "Alchemy API key save failed: \(error.localizedDescription, privacy: .public)")
      self.error = "Failed to save Alchemy API key: \(error.localizedDescription)"
    }
  }

  /// Removes the Alchemy API key from the synced Keychain. Subsequent
  /// sync cycles will produce `WalletSyncError.missingApiKey` until a
  /// new key is saved.
  func clearAlchemyApiKey() {
    alchemyKeyStore.clear()
  }
}

// Features/Settings/SharedRegistryStore.swift

import Foundation
import OSLog

/// App-level shared store of the registry data. Replaces the data side
/// of the per-session `CryptoTokenStore` so spam decisions, discovered-
/// token resolutions, provider mappings, and `registrationsVersion`
/// changes are visible to every profile session at once.
///
/// **Responsibility split.** Owns the registry-data fields
/// (`registrations`, `instruments`, `providerMappings`,
/// `registrationsVersion`) and the methods that mutate the shared
/// registry (`setStatus`, `removeRegistration`, `loadRegistrations`).
/// Per-session UI state — `isLoading`, `error`, `onRegistrationsChanged`
/// — lives in the per-session `CryptoTokenStore` façade, which proxies
/// data reads through this store and catches mutation errors locally
/// so a transient failure in one session doesn't leak onto every
/// Settings screen.
///
/// The shared store does **not** carry an `error` field. Mutation
/// methods throw to the caller; the per-session wrapper catches and
/// surfaces errors locally so one session's transient error doesn't
/// leak onto every Settings screen.
///
/// **Subscription lifetime.** Subscribes once to
/// `registry.observeChanges()` for the lifetime of the store; the
/// observation `Task` is started in `init` and cancelled in `deinit`.
/// `[weak self]` is required to break the retain cycle the stored
/// task would otherwise hold.
@MainActor
@Observable
final class SharedRegistryStore {
  private(set) var registrations: [CryptoRegistration] = []
  private(set) var instruments: [Instrument] = []
  private(set) var providerMappings: [String: CryptoProviderMapping] = [:]

  /// Monotonic counter bumped after every successful registry mutation.
  /// Views that derive per-account valued positions pin a `.task(id:)`
  /// against this so a `.spam` flip in preferences re-fires the
  /// per-row valuator without the user having to navigate away.
  /// Issue #790.
  private(set) var registrationsVersion: Int = 0

  /// Monotonic guard for `loadRegistrations`. The observation task and direct
  /// callers can both trigger a reload, and the local mutations below update
  /// the lists synchronously; a stale `allCryptoRegistrations()` result that
  /// resumes last could clobber a fresher reload or resurrect a just-removed
  /// row. Each reload and each local mutation bumps this; a reload drops its
  /// publish if the counter advanced while it was suspended.
  /// `@ObservationIgnored` — a pure guard counter no view reads. See #1209.
  @ObservationIgnored private var loadGeneration: UInt64 = 0

  // The `unpricedRegistrations` / `unpricedCount` /
  // `spamRegistrations` filters live on the per-session
  // `CryptoTokenStore` façade — every UI consumer goes through it,
  // and the filters there already operate on `self.registrations`,
  // which delegates to this store's `registrations` field. Hosting a
  // duplicate computed property here added an unreachable surface.

  private let registry: any InstrumentRegistryRepository
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "SharedRegistryStore")
  private var observationTask: Task<Void, Never>?

  init(
    registry: any InstrumentRegistryRepository
  ) {
    self.registry = registry

    let stream = registry.observeChanges()
    self.observationTask = Task { @MainActor [weak self] in
      for await _ in stream {
        await self?.loadRegistrations()
      }
    }
  }

  deinit {
    // Swift 6 makes `deinit` nonisolated; reading the `@MainActor`-
    // isolated `observationTask` requires `MainActor.assumeIsolated`.
    // The store is owned by `SyncCoordinator.sharedRegistryStore`,
    // which is `@MainActor`, so the only deallocation path is from
    // the main actor (e.g., when the coordinator itself releases the
    // last strong reference during sign-out / account-switch). The
    // assumption therefore holds in practice; if a future refactor
    // adds a non-`@MainActor` owner this trap fires immediately
    // instead of silently racing the observation infrastructure.
    MainActor.assumeIsolated {
      observationTask?.cancel()
    }
  }

  // MARK: - Reads

  /// Reloads `registrations`, `instruments`, and `providerMappings`
  /// from the registry. Fired automatically by the observation task on
  /// every registry mutation; callers may also invoke directly to
  /// force a refresh.
  ///
  /// Errors are logged via `os.Logger`; the previous data is left in
  /// place. Per-session UI surfaces invoke this through the
  /// `CryptoTokenStore` façade, which converts thrown errors into UI
  /// state — this method's call from the observation task has no UI
  /// caller and intentionally does not propagate.
  func loadRegistrations() async {
    loadGeneration &+= 1
    let generation = loadGeneration
    do {
      let loaded = try await registry.allCryptoRegistrations()
      // Drop this reload if a later reload or a local mutation bumped the
      // counter while `allCryptoRegistrations()` was in flight — publishing our
      // now-stale snapshot could clobber it or resurrect a removed row (#1209).
      guard generation == loadGeneration else { return }
      registrations = loaded
      instruments = loaded.map(\.instrument)
      providerMappings = Dictionary(
        loaded.map { ($0.mapping.instrumentId, $0.mapping) },
        uniquingKeysWith: { _, last in last })
    } catch {
      logger.error(
        "Failed to load crypto registrations: \(error, privacy: .public)")
    }
  }

  // MARK: - Mutations

  /// Removes a registration. Throws on registry failure. Per-session
  /// side effects (price-cache purge, conversion-cache invalidation)
  /// live in `CryptoTokenStore` so each session invalidates its own
  /// caches against its own services.
  func removeRegistration(_ registration: CryptoRegistration) async throws {
    try await registry.remove(id: registration.id)
    registrations.removeAll { $0.id == registration.id }
    instruments.removeAll { $0.id == registration.id }
    providerMappings.removeValue(forKey: registration.id)
    registrationsVersion &+= 1
    loadGeneration &+= 1  // supersede any in-flight reload (see #1209)
  }

  /// Convenience overload — removes the registration backing an
  /// instrument by id.
  func removeInstrument(_ instrument: Instrument) async throws {
    guard
      let registration = registrations.first(where: {
        $0.instrument.id == instrument.id
      })
    else { return }
    try await removeRegistration(registration)
  }

  /// Persists a new `pricingStatus` for an existing registration.
  /// Throws on registry failure; the local in-memory `registrations`
  /// list is left untouched on failure (the next observation tick
  /// reloads from the registry). Per-session conversion-cache
  /// invalidation lives in `CryptoTokenStore`.
  func setStatus(
    _ status: TokenPricingStatus,
    for registration: CryptoRegistration
  ) async throws {
    var updated = registration
    updated.pricingStatus = status
    try await registry.update(updated)
    if let index = registrations.firstIndex(where: { $0.id == registration.id }) {
      registrations[index] = updated
    }
    registrationsVersion &+= 1
    loadGeneration &+= 1  // supersede any in-flight reload (see #1209)
  }
}

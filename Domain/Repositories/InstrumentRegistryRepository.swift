// Domain/Repositories/InstrumentRegistryRepository.swift
import Foundation

/// The authoritative source of instruments visible to a profile. Stock and
/// crypto instruments are stored in the profile's CloudKit-synced
/// `InstrumentRecord` table; fiat instruments are ambient and synthesized
/// from `Locale.Currency.isoCurrencies`.
protocol InstrumentRegistryRepository: InstrumentChangeObserving {
  /// Every instrument visible to the profile: stock + crypto rows from the
  /// database, merged with the ambient fiat ISO list from
  /// `Locale.Currency.isoCurrencies`. De-duplicated by `Instrument.id`
  /// (stored row wins on collision with an ambient fiat entry).
  /// Throws on a backing-store failure (e.g. database unavailable).
  func all() async throws -> [Instrument]

  /// All registered crypto instruments paired with their provider mappings.
  /// Rows whose three provider-mapping fields are all nil are skipped — they
  /// cannot be priced. (Such rows can arise from an auto-insert via
  /// `ensureInstrument` for a CSV-imported crypto position before the user
  /// has resolved its mapping.)
  /// Throws on a backing-store failure.
  func allCryptoRegistrations() async throws -> [CryptoRegistration]

  /// Looks up a single crypto registration by its `Instrument.id`. Returns
  /// `nil` when no row exists for that id, when the row exists but has no
  /// provider mapping (all three mapping columns nil — e.g. an auto-insert
  /// from CSV import that never went through the picker), or when the row
  /// exists but is not a crypto kind.
  ///
  /// Used by `CryptoTokenDiscoveryService` as the fast existence check
  /// before kicking off a network resolve. Implementations must be safe to
  /// call concurrently with other reads and writes — the wallet sync's
  /// build phase issues many concurrent lookups for the same key.
  /// Throws on a backing-store failure.
  func cryptoRegistration(byId id: String) async throws -> CryptoRegistration?

  /// Registers (or upserts) a crypto instrument with its provider mapping.
  /// Re-registering an id that already exists overwrites the mapping and
  /// mutable metadata fields rather than duplicating the row. Invokes the
  /// implementation's sync-queue hook after a successful write.
  ///
  /// - Precondition: `instrument.kind == .cryptoToken`. Passing any other
  ///   kind is a programmer error and traps.
  func registerCrypto(
    _ instrument: Instrument, mapping: CryptoProviderMapping
  ) async throws

  /// Registers (or upserts) a crypto instrument with its provider
  /// mapping **and** sets `pricingStatus` to `status` — all in a single
  /// backing-store write, so the implementation's sync-queue hook fires
  /// exactly once against the final committed state.
  ///
  /// Differs from `registerCrypto(_:mapping:)`, which preserves an
  /// existing row's `pricingStatus` (defaulting to `.priced` only on
  /// insert) and therefore needs a follow-up `update(_:)` whenever the
  /// caller has a freshly-computed status to enforce. The
  /// discovery/resolution path (`CryptoTokenDiscoveryService`
  /// `.performResolution`) routes through this overload so a newly
  /// discovered token never produces two `onRecordChanged` fan-outs and
  /// never exposes the narrow window where CKSyncEngine could upload the
  /// row carrying a stale status. See issue #895.
  ///
  /// - Precondition: `instrument.kind == .cryptoToken`. Passing any other
  ///   kind is a programmer error and traps.
  func registerCrypto(
    _ instrument: Instrument,
    mapping: CryptoProviderMapping,
    forcingStatus status: TokenPricingStatus
  ) async throws

  /// Registers (or upserts) a stock instrument. Stock rows carry no
  /// provider-mapping fields; Yahoo's lookup key is the instrument's own
  /// ticker. Invokes the implementation's sync-queue hook after a
  /// successful write.
  ///
  /// - Precondition: `instrument.kind == .stock`. Passing any other
  ///   kind is a programmer error and traps.
  func registerStock(_ instrument: Instrument) async throws

  /// Persists a new `pricingStatus` for an existing crypto registration,
  /// leaving every other column unchanged. Used by user-mutation paths
  /// (e.g. the Discovered Tokens inbox / Spam tokens management UI) that
  /// flip a token between `.priced` / `.unpriced` / `.spam` without
  /// rewriting its provider mapping. Invokes the implementation's
  /// sync-queue hook on success.
  ///
  /// Implementations rewrite only `pricingStatus`; `instrument` and
  /// `mapping` on the supplied `registration` are used solely to locate
  /// the row. Callers wanting to rewrite the provider mapping should
  /// call `registerCrypto(_:mapping:)`, which upserts the full row.
  ///
  /// Throws `BackendError.notFound(_:)` when no row is registered for
  /// `registration.instrument.id` — callers must have an existing
  /// registration in hand. To insert a brand-new registration, call
  /// `registerCrypto(_:mapping:)` instead.
  func update(_ registration: CryptoRegistration) async throws

  /// Removes a registered instrument by id. No-op for fiat ids and for
  /// ids that are not currently registered — does not throw. Invokes the
  /// implementation's sync-queue hook after a successful delete.
  func remove(id: String) async throws

  // `observeChanges() -> AsyncStream<Void>` is inherited from the
  // narrow `InstrumentChangeObserving` seam (which per-profile stores
  // depend on without pulling in the full registry surface). For this
  // repository the stream fires for **both local mutations and
  // remote-arriving changes**: local mutations (`registerCrypto`,
  // `registerStock`, `update`, `remove`) fan out synchronously inside
  // the corresponding method; remote-arriving rows from
  // `ProfileIndexSyncHandler.applyRemoteChanges` (the profile-index
  // zone carries `InstrumentRecord`) fan out via the handler's
  // injected `onInstrumentRemoteChange` closure, which calls
  // `notifyExternalChange()` on the @MainActor-confined repository.
  // Subscribers see both directions through the single stream — no
  // second per-profile `SyncCoordinator` subscription is required.
  // After a tick, callers re-fetch via `all()` /
  // `allCryptoRegistrations()`; the `Void` payload is a signal, not a
  // diff.
}

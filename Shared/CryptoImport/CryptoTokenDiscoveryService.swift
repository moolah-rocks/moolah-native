import Foundation
import OSLog

/// Resolves on-chain token addresses to `CryptoRegistration` rows.
///
/// Concurrent calls for the same `(chainId, contractAddress)` are coalesced
/// via the in-flight `Task` pattern: the first caller starts the resolution,
/// later callers `await` the same `Task<CryptoRegistration, Error>`. The
/// actor serialises the "check repository → launch resolution → store
/// result" critical section so the registry sees at most one new row per
/// unique key, even under heavy parallel-build-phase contention.
///
/// Resolution algorithm:
///
/// 1. Fast path — return any existing registration from the registry.
/// 2. Resolve provider mappings via `CryptoRegistrationResolver`
///    (CoinGecko by contract → CryptoCompare → Binance).
/// 3. Apply the design's status precedence (issue #1102):
///    - `CanonicalTokenRegistry.isImpersonation` → `.spam` (a token reusing
///      a popular token's symbol at a non-canonical address, ahead of even a
///      provider price).
///    - resolver succeeded with at least one provider id → `.priced`.
///    - no provider price but `CryptoSpamHeuristics` flags the name/symbol
///      (embedded URL/domain or airdrop-"invitation" phrasing) → `.spam`.
///      Runs only on otherwise-`.unpriced` tokens so a listed
///      domain-branded token like yearn.finance keeps its price.
///    - else → `.unpriced` (surfaces in the Discovered Tokens inbox).
/// 4. Persist via the registry. Status is sticky-positive: once a row
///    transitions out of `.unpriced`, the next sync cycle leaves it alone.
///
/// Periodic re-resolution (`reResolve`) is the hook surface for
/// `SyncedAccountStore`. The actual scheduling — at most once per day
/// per `.unpriced` token, per design — lives in the sync store.
/// See issue #753 for the cadence tuning.
actor CryptoTokenDiscoveryService {
  private var inFlight: [String: Task<CryptoRegistration, Error>] = [:]
  private let registry: any InstrumentRegistryRepository
  private let resolver: any CryptoRegistrationResolver
  /// Resolver that redirects L2 native/ERC-20 instruments onto their
  /// canonical mainnet id (e.g. OP native ETH → `1:native`) before persisting.
  /// Defaulted so existing call sites compile unchanged.
  private let canonicalResolver: CanonicalInstrumentResolver
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "CryptoTokenDiscovery")

  init(
    registry: any InstrumentRegistryRepository,
    resolver: any CryptoRegistrationResolver,
    canonicalResolver: CanonicalInstrumentResolver = CanonicalInstrumentResolver()
  ) {
    self.registry = registry
    self.resolver = resolver
    self.canonicalResolver = canonicalResolver
  }

  /// Returns the existing `CryptoRegistration` if one is registered for
  /// `(chain, contractAddress)`, otherwise resolves and persists a new one.
  /// Concurrent callers for the same key all `await` the same in-flight
  /// `Task`; the underlying network round-trip executes once.
  ///
  /// Thin wrapper around `resolveOrLoad(chainId:...)` for callers that
  /// already hold a `ChainConfig`.
  func resolveOrLoad(
    chain: ChainConfig,
    contractAddress: String?,
    symbol: String,
    name: String,
    decimals: Int
  ) async throws -> CryptoRegistration {
    try await resolveOrLoad(
      chainId: chain.chainId,
      contractAddress: contractAddress,
      symbol: symbol,
      name: name,
      decimals: decimals)
  }

  /// Resolves by raw EVM chain id.
  ///
  /// Concurrent callers for the same `(chainId, contractAddress)` are
  /// coalesced via the in-flight `Task` pattern — the actor serialises the
  /// "check repository → launch resolution → store result" critical section
  /// so at most one new row per unique key reaches the registry.
  func resolveOrLoad(
    chainId: Int,
    contractAddress: String?,
    symbol: String,
    name: String,
    decimals: Int
  ) async throws -> CryptoRegistration {
    let instrument = Instrument.crypto(
      chainId: chainId,
      contractAddress: contractAddress,
      symbol: symbol,
      name: name,
      decimals: decimals)

    if let existing = try await registry.cryptoRegistration(byId: instrument.id) {
      return existing
    }
    if let task = inFlight[instrument.id] {
      return try await task.value
    }

    let task = Task<CryptoRegistration, Error> { [self] in
      try await performResolution(instrument: instrument)
    }
    inFlight[instrument.id] = task
    do {
      let result = try await task.value
      // Waiters capture the Task by value before awaiting `.value` and
      // never re-read `inFlight` after resuming, so clearing the slot
      // here is safe regardless of waiter resume order.
      inFlight[instrument.id] = nil
      return result
    } catch {
      inFlight[instrument.id] = nil
      throw error
    }
  }

  // MARK: - Resolution algorithm

  /// Performs the full resolution algorithm for a token.
  ///
  /// Status precedence (issue #1102): canonical-registry impersonation wins
  /// outright, then a provider price, then the local spam heuristic on an
  /// otherwise-`.unpriced` token, else `.unpriced`.
  ///
  /// - Parameter instrument: Pre-built crypto instrument (carries chainId,
  ///   contractAddress, symbol, name, decimals).
  private func performResolution(
    instrument: Instrument
  ) async throws -> CryptoRegistration {
    let isNative = instrument.contractAddress == nil
    // Crypto instruments always carry a non-nil chainId; non-crypto
    // instruments must never be passed to this method.
    guard let chainId = instrument.chainId else {
      preconditionFailure(
        "performResolution requires a crypto instrument with a chainId; got \(instrument.id)")
    }

    // Impersonation is a pure, synchronous registry lookup — check it before
    // the provider round-trip so a known impersonator (a fake "OP", a
    // counterfeit stablecoin: a popular token's symbol at a non-canonical
    // address) is flagged outright, ahead of any provider price, with no
    // wasted network call. Per issue #1102.
    if CanonicalTokenRegistry.isImpersonation(
      chainId: chainId,
      contractAddress: instrument.contractAddress,
      symbol: instrument.ticker ?? instrument.name)
    {
      logger.debug(
        "Canonical-registry impersonation flagged \(instrument.id, privacy: .public)")
      return try await persist(
        instrument, mapping: emptyMapping(for: instrument.id), status: .spam)
    }

    // Resolution via provider chain. A non-cancellation throw means "no
    // mapping" — a normal outcome (e.g. an obscure ERC-20 with no listing
    // on any provider). `resolveSilently` swallows that case and returns
    // `nil`; only `CancellationError` propagates so a cancelled sync
    // never writes a half-resolved row.
    let resolved = try await resolveSilently(
      chainId: chainId,
      contractAddress: instrument.contractAddress,
      symbol: instrument.ticker ?? instrument.name,
      isNative: isNative)

    try Task.checkCancellation()

    let mapping: CryptoProviderMapping
    let status: TokenPricingStatus
    if let resolved, resolved.mapping.hasProviderMapping {
      status = .priced
      mapping = resolved.mapping
    } else if let signal = CryptoSpamHeuristics.spamSignal(
      name: instrument.name, symbol: instrument.ticker)
    {
      // No provider price and the name/symbol carries a spam signal (an
      // embedded URL/domain or airdrop-"invitation" phrasing) — issue #1102.
      logger.debug(
        "Local spam heuristic (\(signal.rawValue, privacy: .public)) flagged \(instrument.id, privacy: .public)"
      )
      status = .spam
      mapping = emptyMapping(for: instrument.id)
    } else {
      status = .unpriced
      mapping = emptyMapping(for: instrument.id)
    }

    return try await persist(instrument, mapping: mapping, status: status)
  }

  /// Lands the mapping and this discovery pass's status decision in a single
  /// registry write. The plain `registerCrypto(_:mapping:)` preserves an
  /// existing row's `pricingStatus` (default `.priced` only on insert), so
  /// enforcing a freshly-computed status used to need a follow-up `update(_:)`
  /// — two writes, two `onRecordChanged` fan-outs, and a narrow window where
  /// CKSyncEngine could upload the row with a stale status. `forcingStatus:`
  /// collapses that to one write that fires the hook exactly once against the
  /// final state (issue #895).
  private func persist(
    _ instrument: Instrument,
    mapping: CryptoProviderMapping,
    status: TokenPricingStatus
  ) async throws -> CryptoRegistration {
    try await registry.registerCrypto(
      instrument, mapping: mapping, forcingStatus: status)
    return CryptoRegistration(
      instrument: instrument, mapping: mapping, pricingStatus: status)
  }

  /// Re-runs resolution for an `.unpriced` registration.
  ///
  /// Idempotent: re-reads the registry to find the *current* status before
  /// deciding whether to re-resolve. If the live row is not
  /// `.unpriced` (user marked it spam, or another path resolved it),
  /// returns that row without issuing any network calls. This preserves
  /// the design's "user intent wins" property — a spam classification
  /// made on another device while we were idling between daily cycles
  /// must not be clobbered by an automatic re-resolution.
  ///
  /// `SyncedAccountStore` is the only intended caller and is
  /// responsible for the daily-cadence gate (issue #753).
  func reResolve(
    _ registration: CryptoRegistration,
    chain: ChainConfig
  ) async throws -> CryptoRegistration {
    let id = registration.instrument.id
    let current = try await registry.cryptoRegistration(byId: id) ?? registration
    guard current.pricingStatus == .unpriced else { return current }

    // Coalescing mirrors `resolveOrLoad`: concurrent callers for the same
    // instrument id share one in-flight resolution Task.
    if let task = inFlight[id] { return try await task.value }
    let task = Task<CryptoRegistration, Error> {
      try await self.performResolution(instrument: current.instrument)
    }
    inFlight[id] = task
    do {
      let result = try await task.value
      // Waiters capture the Task by value before awaiting `.value` and
      // never re-read `inFlight` after resuming, so clearing the slot
      // here is safe regardless of waiter resume order.
      inFlight[id] = nil
      return result
    } catch {
      inFlight[id] = nil
      throw error
    }
  }

  // MARK: - Helpers

  private func resolveSilently(
    chainId: Int,
    contractAddress: String?,
    symbol: String,
    isNative: Bool
  ) async throws -> CryptoRegistration? {
    do {
      return try await resolver.resolveRegistration(
        chainId: chainId,
        contractAddress: contractAddress,
        symbol: symbol,
        isNative: isNative)
    } catch is CancellationError {
      // Cooperative cancellation propagates — never write a half-resolved
      // row when the caller's task hierarchy is unwinding.
      throw CancellationError()
    } catch {
      logger.debug(
        "Provider resolution returned no mapping for chain \(chainId, privacy: .public) (\(error.localizedDescription, privacy: .public))"
      )
      return nil
    }
  }

  private func emptyMapping(for instrumentId: String) -> CryptoProviderMapping {
    CryptoProviderMapping(
      instrumentId: instrumentId,
      coingeckoId: nil,
      cryptocompareSymbol: nil,
      binanceSymbol: nil)
  }

}

import Foundation
import OSLog

extension InstrumentRegistryRepository {
  /// Re-runs provider detection over every already-registered crypto
  /// instrument, filling only the nil provider columns from the cached
  /// Binance / CoinGecko catalogs and merging the result back in. This is
  /// the startup pass that fixes #1140 for tokens that were registered before
  /// a provider's catalog had loaded: their mapping gains the now-available
  /// ids without a network round-trip.
  ///
  /// Only rows whose identity is already contract-confirmed (at least one
  /// resolved provider id) and that are not `.spam` are reconciled —
  /// `allCryptoRegistrations()` also returns `.spam` / `.unpriced` stubs
  /// with an all-nil mapping (e.g. a spam ERC-20 from discovery carrying a
  /// copied ticker), and those must NOT have a Binance symbol attributed from
  /// their unverified ticker. The Binance `<TICKER>USDT` attribution is safe
  /// precisely because the surviving rows already carry a contract-resolved
  /// provider id, so the ticker is confirmed rather than user/spam-supplied —
  /// the #790 hazard.
  ///
  /// Merge-only: a populated column is never overwritten (enforced by
  /// `CryptoProviderMapping.merging`), and a row whose merged mapping is
  /// unchanged is not rewritten — no sync churn. Per-token failures are
  /// logged and skipped; cancellation returns immediately. Best-effort
  /// otherwise (no throws out of the method).
  func reconcileProviderMappings(using catalogs: ProviderCatalogLookups) async {
    let logger = Logger(
      subsystem: "com.moolah.app", category: "InstrumentRegistryReconcile")

    let registrations: [CryptoRegistration]
    do {
      registrations = try await allCryptoRegistrations()
    } catch {
      logger.warning(
        """
        reconcileProviderMappings: load failed: \
        \(error.localizedDescription, privacy: .public)
        """
      )
      return
    }

    do {
      try Task.checkCancellation()
    } catch {
      return
    }

    for registration in registrations {
      do {
        try Task.checkCancellation()
        // #790: only re-detect rows whose identity is already
        // contract-confirmed (>=1 resolved provider id). An all-nil mapping
        // (e.g. a .spam/.unpriced stub from discovery carrying a copied
        // ticker) must NOT get a Binance symbol attributed from its
        // unverified ticker. Also skip .spam outright — there's nothing to
        // gain reconciling a hidden token.
        guard registration.mapping.hasProviderMapping,
          registration.pricingStatus != .spam
        else { continue }
        let merged = try await mergedMapping(for: registration, using: catalogs)
        guard merged != registration.mapping else { continue }
        try await registerCrypto(registration.instrument, mapping: merged)
      } catch is CancellationError {
        return
      } catch {
        logger.warning(
          """
          reconcileProviderMappings: \(registration.id, privacy: .public): \
          \(error.localizedDescription, privacy: .public)
          """
        )
      }
    }
  }

  /// Builds an additive candidate mapping by filling only the nil columns
  /// of `registration.mapping` from the caches, then merges it back. Only
  /// nil columns trigger a cache call, so a fully-mapped row does no work.
  /// The independent cache lookups fan out via `async let`, and
  /// `CancellationError` propagates out so the loop's cancellation handler
  /// can exit promptly mid-token.
  private func mergedMapping(
    for registration: CryptoRegistration,
    using catalogs: ProviderCatalogLookups
  ) async throws -> CryptoProviderMapping {
    let mapping = registration.mapping
    let instrument = registration.instrument
    let ticker = (instrument.ticker ?? "").uppercased()

    async let newBinance = detectBinance(
      existing: mapping.binanceSymbol, ticker: ticker, catalogs: catalogs)
    async let newCoinGecko = detectCoinGecko(
      existing: mapping.coingeckoId, instrument: instrument, catalogs: catalogs)

    let (binance, coinGecko) = await (newBinance, newCoinGecko)
    try Task.checkCancellation()

    let candidate = CryptoProviderMapping(
      instrumentId: mapping.instrumentId,
      coingeckoId: coinGecko,
      cryptocompareSymbol: nil,
      binanceSymbol: binance)
    return mapping.merging(candidate)
  }

  private func detectBinance(
    existing: String?, ticker: String, catalogs: ProviderCatalogLookups
  ) async -> String? {
    guard existing == nil, !ticker.isEmpty else { return existing }
    guard await catalogs.binance.hasUsdtPair(base: ticker) else { return nil }
    return "\(ticker)USDT"
  }

  private func detectCoinGecko(
    existing: String?, instrument: Instrument, catalogs: ProviderCatalogLookups
  ) async -> String? {
    guard existing == nil, let contractAddress = instrument.contractAddress,
      let chainId = instrument.chainId, let coinGecko = catalogs.coinGecko
    else { return existing }
    return await coinGecko.localContractMatch(
      chainId: chainId, contractAddress: contractAddress)?.coingeckoId
  }
}

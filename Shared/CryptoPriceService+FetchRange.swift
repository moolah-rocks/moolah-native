import Foundation

// MARK: - First-trade confirmation + window-fetch coalescing

extension CryptoPriceService {
  /// Sets `caches[tokenId].firstTradedOn` to `earliestDate` and persists it
  /// when a backward window walk terminated on no-progress with no operational
  /// failure and `firstTradedOn` has not yet been confirmed. Idempotent:
  /// skipped when `firstTradedOn` is already set or `earliestDate` is empty.
  ///
  /// Call only after a backward window exits with `boundsKeys == before` and
  /// *before* re-reading bounds: bounds haven't moved, so the current
  /// `earliestDate` is the confirmed floor.
  ///
  /// `internal` (not `private`) so the `PriceSeriesOrchestrating`
  /// `confirmFirstTradeOnBackwardExhaustion` plug in the sibling
  /// `CryptoPriceService+PriceSeriesOrchestrating.swift` extension can call it.
  func confirmFirstTradedOnIfExhausted(
    tokenId: String,
    lastFetchError: (any Error)?
  ) async throws {
    guard lastFetchError == nil,
      var cache = caches[tokenId],
      cache.firstTradedOn == nil,
      !cache.earliestDate.isEmpty
    else { return }
    cache.firstTradedOn = cache.earliestDate
    caches[tokenId] = cache
    try await persistFirstTradedOn(tokenId: tokenId, date: cache.earliestDate)
  }

  /// Returns the current cache bounds for `tokenId` as `DateKey` (`Int32`
  /// yyyymmdd) values. Returns `(nil, nil)` when the cache is cold.
  func boundsKeys(tokenId: String) -> (earliest: Int32?, latest: Int32?) {
    guard let cache = caches[tokenId] else { return (nil, nil) }
    return (
      DateKey.from(isoString: cache.earliestDate),
      DateKey.from(isoString: cache.latestDate)
    )
  }

  /// Converts a `ClosedRange<String>` of ISO `YYYY-MM-DD` bounds into a
  /// `ClosedRange<Date>`. Falls back to `now()` for any unparseable bound
  /// and ensures the result is non-inverted.
  func parseInterval(_ iso: ClosedRange<String>) -> ClosedRange<Date> {
    let lower = dateFormatter.date(from: iso.lowerBound) ?? now()
    let upper = dateFormatter.date(from: iso.upperBound) ?? now()
    return lower...max(lower, upper)
  }

  /// Coalesces concurrent per-window fetches for the same token: if a fetch
  /// is already in flight, await its result (sharing the round-trip) and
  /// return. Otherwise starts a new `Task`, registers it in `extensionTasks`
  /// for sharing, and awaits the result with cooperative-cancellation
  /// forwarding. The coalescing key is the token id — callers must ensure
  /// they only issue one window fetch at a time per token.
  func fetchWindowCoalesced(
    instrument: Instrument,
    mapping: CryptoProviderMapping,
    fetchInterval: ClosedRange<Date>
  ) async throws {
    let tokenId = instrument.id
    if let inFlight = extensionTasks[tokenId] {
      do {
        try await inFlight.task.value
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Owner's provider error; the no-progress guard handles it.
      }
      return
    }
    let requestId = UUID()
    let task = Task<Void, Error> { [self] in
      try await self.fetchRange(
        instrument: instrument,
        mapping: mapping,
        from: fetchInterval.lowerBound,
        to: fetchInterval.upperBound)
    }
    extensionTasks[tokenId] = (requestId, task)
    defer {
      if extensionTasks[tokenId]?.id == requestId {
        extensionTasks.removeValue(forKey: tokenId)
      }
    }
    _ = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}

// MARK: - Provider fallback for a date range

extension CryptoPriceService {
  /// Runs the provider fallback chain for a date range, tolerating per-provider
  /// failures and only throwing when every client errored. `internal` (called
  /// from `prices(for:mapping:in:)` in `CryptoPriceService.swift`).
  func fetchRange(
    instrument: Instrument, mapping: CryptoProviderMapping, from: Date, to: Date
  ) async throws {
    let tokenId = instrument.id
    let symbol = instrument.ticker ?? instrument.name
    var operationalError: (any Error)?
    var operationalProvider: SyncProvider?
    for client in clients {
      do {
        let fetched = try await client.dailyPrices(for: mapping, in: from...to)
        if !fetched.isEmpty {
          let delta = mergeReturningDelta(
            tokenId: tokenId, symbol: symbol, newPrices: fetched)
          if !delta.isEmpty {
            try await persistDelta(tokenId: tokenId, deltaRecords: delta)
          }
          return
        }
      } catch is CancellationError {
        // Surface cooperative cancellation unchanged rather than wrapping it
        // into a provider outage. Mirrors `fetchWindowCoalesced`.
        throw CancellationError()
      } catch CryptoPriceError.noProviderMapping {
        // Routing decision — this client has no symbol for the token
        // (e.g. USDT on Binance). Skip silently rather than attributing
        // a non-existent outage to a provider that's behaving as designed.
        continue
      } catch let walletError as WalletSyncError
        where walletError.kind == .missingApiKey || walletError.kind == .invalidApiKey
      {
        // Structural failure — the provider definitively cannot contribute
        // (no API key, or key rejected). Analogous to noProviderMapping.
        // Do NOT treat as a transient outage; skip to the next client.
        // Note: .providerMalformedResponse, .rateLimited, and .network all
        // fall through to the operational capture path below.
        continue
      } catch {
        operationalError = error
        operationalProvider = client.syncProvider
        continue
      }
    }
    if let error = operationalError {
      // Rethrow an existing WalletSyncError unchanged — it already carries
      // its provider and kind; re-attributing would clobber the source.
      if let walletError = error as? WalletSyncError {
        throw walletError
      }
      throw WalletSyncError(
        provider: operationalProvider,
        kind: .network(underlyingDescription: String(describing: error)))
    }
  }
}

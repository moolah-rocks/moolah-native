// Shared/CryptoPriceService+FetchRange.swift

import Foundation

// MARK: - Contiguous bounded extension (single price)

extension CryptoPriceService {
  /// Extends the cache contiguously toward `dateString` using bounded 30-day
  /// windows driven by `ContiguousFetchPlanner`, anchored at the current cache
  /// boundary. The loop exits when the date is covered, when no progress was
  /// made (provider genuinely has no data for this window — horizon-restricted
  /// providers stop here rather than jumping `latest` over a void), or when a
  /// provider error occurs on every window attempt.
  func extendContiguously(
    instrument: Instrument,
    mapping: CryptoProviderMapping,
    tokenId: String,
    dateString: String
  ) async throws -> Decimal {
    let requestedKey = DateKey.from(isoString: dateString) ?? Int32.max
    let todayKey =
      DateKey.from(isoString: dateFormatter.string(from: now())) ?? requestedKey
    let config = ContiguousFetchPlanner.Config(windowDays: 30, forwardBuffer: 2)
    var lastFetchError: (any Error)?
    var guardSteps = 0
    while guardSteps < 250 {
      guardSteps += 1
      let bounds = boundsKeys(tokenId: tokenId)
      guard
        let window = ContiguousFetchPlanner.nextWindow(
          earliest: bounds.earliest,
          latest: bounds.latest,
          requested: requestedKey,
          today: todayKey,
          config: config)
      else { break }  // requested date now in range
      let before = bounds
      let fetchInterval = parseInterval(
        DateKey.isoString(window.lowerBound)...DateKey.isoString(window.upperBound))
      do {
        try await fetchWindowCoalesced(
          instrument: instrument, mapping: mapping, fetchInterval: fetchInterval)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Provider chain fully failed for this window; surface error below.
        lastFetchError = error
        break
      }
      if let hit = try midLoopCacheHit(tokenId: tokenId, dateString: dateString) {
        return hit
      }
      // No progress (bounds unchanged) means genuine no-more-data; stop and
      // let a later call re-query the boundary (recent data may publish later).
      if boundsKeys(tokenId: tokenId) == before {
        let wasBackward = before.earliest.map { requestedKey < $0 } ?? false
        if wasBackward {
          try await confirmFirstTradedOnIfExhausted(
            tokenId: tokenId, lastFetchError: lastFetchError)
        }
        break
      }
    }
    if guardSteps >= 250 {
      logger.warning(
        "extendContiguously: guard limit reached for \(tokenId, privacy: .public) on \(dateString, privacy: .public)"
      )
    }
    return try resolveAfterExtension(
      tokenId: tokenId, dateString: dateString, fetchError: lastFetchError)
  }

  /// Covers `[lowerKey, upperKey]` contiguously: bounded planner loop toward
  /// each endpoint with a no-progress guard — stops a direction the moment a
  /// window yields no boundary progress so a horizon-restricted provider
  /// cannot leave an interior gap. Used by `prices(for:mapping:in:)`.
  func coverRangeContiguously(
    instrument: Instrument,
    mapping: CryptoProviderMapping,
    tokenId: String,
    lowerKey: Int32,
    upperKey: Int32
  ) async throws {
    var lastFetchError: (any Error)?
    // Forward first, then backward; each window anchors at the live cache bounds.
    for requestedKey in [upperKey, lowerKey] {
      try await extendOneDirection(
        instrument: instrument,
        mapping: mapping,
        tokenId: tokenId,
        requestedKey: requestedKey,
        lastFetchError: &lastFetchError)
    }
    // Surface the last provider error if any endpoint is still uncovered —
    // mirrors resolveAfterExtension so prices(in:) matches price(on:)'s contract.
    if let lastFetchError {
      let todayKey = DateKey.from(isoString: dateFormatter.string(from: now())) ?? upperKey
      let config = ContiguousFetchPlanner.Config(windowDays: 30, forwardBuffer: 2)
      let bounds = boundsKeys(tokenId: tokenId)
      let stillUncovered = [upperKey, lowerKey].contains { key in
        ContiguousFetchPlanner.nextWindow(
          earliest: bounds.earliest,
          latest: bounds.latest,
          requested: key,
          today: todayKey,
          config: config) != nil
      }
      if stillUncovered { throw lastFetchError }
    }
  }

  /// Runs the bounded planner loop for one direction (forward or backward)
  /// within `coverRangeContiguously`. Stops when `requestedKey` is in range,
  /// when no progress is made, or on a provider error. `config` and `todayKey`
  /// are derived from the service's injected clock using the same constants
  /// as `extendContiguously` and `coverRangeContiguously`.
  private func extendOneDirection(
    instrument: Instrument,
    mapping: CryptoProviderMapping,
    tokenId: String,
    requestedKey: Int32,
    lastFetchError: inout (any Error)?
  ) async throws {
    let config = ContiguousFetchPlanner.Config(windowDays: 30, forwardBuffer: 2)
    let todayKey = DateKey.from(isoString: dateFormatter.string(from: now())) ?? requestedKey
    var guardSteps = 0
    while guardSteps < 250 {
      guardSteps += 1
      let bounds = boundsKeys(tokenId: tokenId)
      guard
        let window = ContiguousFetchPlanner.nextWindow(
          earliest: bounds.earliest,
          latest: bounds.latest,
          requested: requestedKey,
          today: todayKey,
          config: config)
      else { break }  // endpoint now in range
      let before = bounds
      let fetchInterval = parseInterval(
        DateKey.isoString(window.lowerBound)...DateKey.isoString(window.upperBound))
      do {
        try await fetchWindowCoalesced(
          instrument: instrument, mapping: mapping, fetchInterval: fetchInterval)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Provider chain failed; capture error and stop this direction.
        lastFetchError = error
        break
      }
      if boundsKeys(tokenId: tokenId) == before {
        let wasBackward = before.earliest.map { requestedKey < $0 } ?? false
        if wasBackward {
          try await confirmFirstTradedOnIfExhausted(
            tokenId: tokenId, lastFetchError: lastFetchError)
        }
        break
      }
    }
    if guardSteps >= 250 {
      logger.warning(
        "coverRangeContiguously: guard limit reached for \(tokenId, privacy: .public)"
      )
    }
  }

  /// Final resolution after the bounded extension loop exits: checks cached
  /// exact hit, prior-trading-day fallback, in-range fallback, and finally
  /// re-throws the last provider error or `noPriceAvailable`. Extracted to
  /// keep `extendContiguously`'s cyclomatic complexity in bounds.
  private func resolveAfterExtension(
    tokenId: String,
    dateString: String,
    fetchError: (any Error)?
  ) throws -> Decimal {
    if let cached = lookupPrice(tokenId: tokenId, dateString: dateString) {
      return cached
    }
    if let fallback = fallbackPrice(tokenId: tokenId, dateString: dateString) {
      return fallback
    }
    if let inRange = try inRangeFallback(tokenId: tokenId, dateString: dateString) {
      return inRange
    }
    if let fetchError {
      throw fetchError
    }
    throw CryptoPriceError.noPriceAvailable(tokenId: tokenId, date: dateString)
  }

  /// Returns the first in-cache price for `dateString` found by exact lookup
  /// or in-range fallback, or `nil` when neither is available. Used by
  /// `extendContiguously`'s mid-loop early-exit check to avoid redundant
  /// window fetches after each successful window advances the cache bounds.
  private func midLoopCacheHit(tokenId: String, dateString: String) throws -> Decimal? {
    if let cached = lookupPrice(tokenId: tokenId, dateString: dateString) {
      return cached
    }
    return try inRangeFallback(tokenId: tokenId, dateString: dateString)
  }

  /// Sets `caches[tokenId].firstTradedOn` to `earliestDate` and persists it
  /// when a backward window walk terminated on no-progress with no operational
  /// failure and `firstTradedOn` has not yet been confirmed. Idempotent:
  /// skipped when `firstTradedOn` is already set or `earliestDate` is empty.
  ///
  /// Call only after a backward window exits with `boundsKeys == before` and
  /// *before* re-reading bounds: bounds haven't moved, so the current
  /// `earliestDate` is the confirmed floor.
  private func confirmFirstTradedOnIfExhausted(
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

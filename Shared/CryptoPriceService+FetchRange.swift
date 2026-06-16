// Shared/CryptoPriceService+FetchRange.swift

import Foundation

// MARK: - Contiguous bounded extension (single price)

extension CryptoPriceService {
  /// Extends the cache contiguously toward `dateString` using bounded
  /// 30-day windows driven by `ContiguousFetchPlanner`. Each iteration
  /// fetches one window anchored at the current cache boundary, so the
  /// cache never jumps its bounds over un-fetched interior days (the
  /// interior-gap bug fixed here). The loop exits when the date is covered,
  /// when no progress was made (provider genuinely has no data for this
  /// window), or when a provider error occurs on every window attempt.
  ///
  /// Unlike the old unbounded `extensionWindow`, a horizon-restricted
  /// provider (e.g. CoinGecko free tier: 365 days) causes the loop to stop
  /// at the edge of its coverage window rather than jumping `latest` all
  /// the way to the requested date and leaving a void.
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
    while guardSteps < 64 {
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
      if let cached = lookupPrice(tokenId: tokenId, dateString: dateString) {
        return cached
      }
      if let inRange = try inRangeFallback(tokenId: tokenId, dateString: dateString) {
        return inRange
      }
      // No progress (bounds unchanged) means genuine no-more-data; stop and
      // let a later call re-query the boundary (recent data may publish later).
      if boundsKeys(tokenId: tokenId) == before { break }
    }
    return try resolveAfterExtension(
      tokenId: tokenId, dateString: dateString, fetchError: lastFetchError)
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
  private func parseInterval(_ iso: ClosedRange<String>) -> ClosedRange<Date> {
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
      _ = try? await inFlight.task.value
      return
    }
    let requestId = UUID()
    let task = Task<Decimal, Error> { [self] in
      try await self.fetchRange(
        instrument: instrument,
        mapping: mapping,
        from: fetchInterval.lowerBound,
        to: fetchInterval.upperBound)
      return 0
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
  /// Runs the provider fallback chain
  /// (CoinGecko → CryptoCompare → Binance) for a date range, tolerating
  /// per-provider failures and only throwing when every client errored.
  /// It is `internal` (not `private`) because it is called from
  /// `prices(for:mapping:in:)` in `CryptoPriceService.swift`; it remains
  /// actor-isolated.
  func fetchRange(
    instrument: Instrument, mapping: CryptoProviderMapping, from: Date, to: Date
  ) async throws {
    let tokenId = instrument.id
    let symbol = instrument.ticker ?? instrument.name
    var lastError: (any Error)?
    var lastProvider: SyncProvider?
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
      } catch {
        lastError = error
        lastProvider = client.syncProvider
        continue
      }
    }
    if let error = lastError {
      throw WalletSyncError(
        provider: lastProvider,
        kind: .network(underlyingDescription: String(describing: error)))
    }
  }
}

// MARK: - Background warming

extension CryptoPriceService {
  /// Background-warm a token's prices over `range`, fetching only the
  /// sub-ranges the in-memory/on-disk cache does not already cover.
  /// Unlike `fetchRange`, surfaces a provider `RateLimitGateError.cooldown`
  /// deadline (so a background warmer can sleep precisely) instead of
  /// wrapping it into a `WalletSyncError`. Idempotent: an already-covered
  /// range fetches nothing and returns `.filled`. See issue #1075.
  func warmRange(
    for instrument: Instrument,
    mapping: CryptoProviderMapping,
    in range: ClosedRange<Date>
  ) async -> WarmOutcome {
    let tokenId = instrument.id
    if !hydratedTokenIds.contains(tokenId) {
      do { try await loadCache(tokenId: tokenId) } catch {
        logger.warning(
          "warmRange: loadCache failed for \(tokenId, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
    let subRanges = uncoveredSubRanges(tokenId: tokenId, range: range)
    if subRanges.isEmpty { return .filled }

    var soonestCooldown: Date?
    var filledAny = false
    for sub in subRanges {
      switch await fetchSubRangeWarming(instrument: instrument, mapping: mapping, range: sub) {
      case .filled:
        filledAny = true
      case .cooledDown(let until):
        soonestCooldown = soonestCooldown.map { min($0, until) } ?? until
      case .unavailable:
        continue
      }
    }
    if let soonestCooldown { return .cooledDown(until: soonestCooldown) }
    return filledAny ? .filled : .unavailable
  }

  /// The sub-ranges of `range` not already covered by the token's cache,
  /// chunked into at most 30-day windows so no single fetch spans an
  /// un-served interior. Mirrors the backward/forward extension decision in
  /// `prices(for:mapping:in:)` — including its boundary-day inversion
  /// guards (`range.lowerBound <= backEnd` and `forwardStart <=
  /// fetchUpperBound`) so a noon-anchored day token immediately adjacent
  /// to a cache bound never builds an inverted `ClosedRange`.
  private func uncoveredSubRanges(
    tokenId: String, range: ClosedRange<Date>
  ) -> [ClosedRange<Date>] {
    let fetchUpperBound = cappedToYesterday(range.upperBound, now: now, timeZone: timeZone)
    guard range.lowerBound <= fetchUpperBound else { return [] }
    let rangeStart = dateFormatter.string(from: range.lowerBound)
    let fetchEndString = dateFormatter.string(from: fetchUpperBound)
    let gregorian = Calendar.utc
    guard let cache = caches[tokenId] else {
      return Self.chunked(range.lowerBound...fetchUpperBound, days: 30)
    }
    var result: [ClosedRange<Date>] = []
    if rangeStart < cache.earliestDate,
      let earliest = dateFormatter.date(from: cache.earliestDate),
      let backEnd = gregorian.date(byAdding: .day, value: -1, to: earliest),
      range.lowerBound <= backEnd
    {
      result += Self.chunked(range.lowerBound...backEnd, days: 30)
    }
    if fetchEndString > cache.latestDate,
      let forwardStart = dateFormatter.date(from: cache.latestDate),
      forwardStart <= fetchUpperBound
    {
      result += Self.chunked(forwardStart...fetchUpperBound, days: 30)
    }
    return result
  }

  /// Splits `range` into consecutive sub-ranges of at most `days` calendar
  /// days (UTC). Used by `uncoveredSubRanges` to cap individual fetches so
  /// a horizon-restricted provider cannot jump the cache bounds over a void.
  static func chunked(_ range: ClosedRange<Date>, days: Int) -> [ClosedRange<Date>] {
    let cal = Calendar.utc
    var result: [ClosedRange<Date>] = []
    var start = range.lowerBound
    while start <= range.upperBound {
      let end: Date
      if let candidate = cal.date(byAdding: .day, value: days, to: start) {
        end = min(candidate, range.upperBound)
      } else {
        end = range.upperBound
      }
      result.append(start...end)
      guard let next = cal.date(byAdding: .day, value: 1, to: end) else { break }
      if next > range.upperBound { break }
      start = next
    }
    return result
  }

  /// Runs the provider fallback chain for one sub-range, surfacing the
  /// soonest cooldown deadline rather than wrapping it into a
  /// `WalletSyncError` the way `fetchRange` does. Returns `.unavailable`
  /// when every client returned empty / a non-cooldown failure.
  private func fetchSubRangeWarming(
    instrument: Instrument, mapping: CryptoProviderMapping, range: ClosedRange<Date>
  ) async -> WarmOutcome {
    let tokenId = instrument.id
    let symbol = instrument.ticker ?? instrument.name
    var soonestCooldown: Date?
    for client in clients {
      do {
        let fetched = try await client.dailyPrices(for: mapping, in: range)
        if !fetched.isEmpty {
          let delta = mergeReturningDelta(tokenId: tokenId, symbol: symbol, newPrices: fetched)
          if !delta.isEmpty {
            try await persistDelta(tokenId: tokenId, deltaRecords: delta)
          }
          return .filled
        }
      } catch let cooldown as RateLimitGateError {
        if case .cooldown(let until) = cooldown {
          soonestCooldown = soonestCooldown.map { min($0, until) } ?? until
        }
        continue
      } catch CryptoPriceError.noProviderMapping {
        // Routing decision — this client has no symbol for the token
        // (e.g. USDT on Binance). Skip silently, same as `fetchRange`.
        continue
      } catch {
        logger.warning(
          "fetchSubRangeWarming: fetch/persist failed for \(tokenId, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        continue
      }
    }
    if let soonestCooldown { return .cooledDown(until: soonestCooldown) }
    return .unavailable
  }
}

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
    let todayKey =
      DateKey.from(isoString: dateFormatter.string(from: now())) ?? upperKey
    let config = ContiguousFetchPlanner.Config(windowDays: 30, forwardBuffer: 2)
    // Forward first, then backward; each window anchors at the live cache bounds.
    for requestedKey in [upperKey, lowerKey] {
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
          // Provider chain failed; stop this direction (cached data is used).
          break
        }
        if boundsKeys(tokenId: tokenId) == before { break }  // no progress — stop
      }
      if guardSteps >= 250 {
        logger.warning(
          "coverRangeContiguously: guard limit reached for \(tokenId, privacy: .public)"
        )
      }
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
  /// Background-warm a token's prices over `range` using the same contiguous
  /// bounded-window loop as `coverRangeContiguously`. Covers both endpoints,
  /// anchoring each window at the live cache bounds and stopping the moment a
  /// window returns no new data — preventing interior gaps from horizon-
  /// restricted providers. Surfaces `RateLimitGateError.cooldown` so
  /// `CryptoPriceWarmer` can sleep precisely. Idempotent. See issue #1075.
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
    let fetchUpperBound = cappedToYesterday(range.upperBound, now: now, timeZone: timeZone)
    guard range.lowerBound <= fetchUpperBound else { return .filled }
    guard
      let upperKey = DateKey.from(isoString: dateFormatter.string(from: fetchUpperBound)),
      let lowerKey = DateKey.from(isoString: dateFormatter.string(from: range.lowerBound))
    else { return .unavailable }
    let todayKey =
      DateKey.from(isoString: dateFormatter.string(from: now())) ?? upperKey
    let config = ContiguousFetchPlanner.Config(windowDays: 30, forwardBuffer: 2)

    // Fast-path: if both endpoints are already within the cached range, there
    // is nothing to fetch. Mirrors the old `subRanges.isEmpty` early exit.
    let existingBounds = boundsKeys(tokenId: tokenId)
    if let earliest = existingBounds.earliest, let latest = existingBounds.latest,
      lowerKey >= earliest, upperKey <= latest
    {
      return .filled
    }

    var filledAny = false
    // Cover forward endpoint first, then backward — mirrors `coverRangeContiguously`.
    for requestedKey in [upperKey, lowerKey] {
      let step = await warmStep(
        instrument: instrument,
        mapping: mapping,
        requestedKey: requestedKey,
        todayKey: todayKey,
        config: config)
      switch step {
      case .filled: filledAny = true
      case .cooledDown: return step
      case .unavailable: continue
      }
    }
    return filledAny ? .filled : .unavailable
  }

  /// Contiguous bounded-window loop toward `requestedKey`, anchored at the
  /// live cache bounds. Returns `.filled` if any window filled data,
  /// `.cooledDown` on a provider rate limit, or `.unavailable` when no window
  /// served data (provider horizon reached). Used by `warmRange`.
  private func warmStep(
    instrument: Instrument,
    mapping: CryptoProviderMapping,
    requestedKey: Int32,
    todayKey: Int32,
    config: ContiguousFetchPlanner.Config
  ) async -> WarmOutcome {
    let tokenId = instrument.id
    var guardSteps = 0
    var filledAny = false
    warmLoop: while guardSteps < 250 {
      guardSteps += 1
      let bounds = boundsKeys(tokenId: tokenId)
      guard
        let window = ContiguousFetchPlanner.nextWindow(
          earliest: bounds.earliest,
          latest: bounds.latest,
          requested: requestedKey,
          today: todayKey,
          config: config)
      else { break warmLoop }  // endpoint already covered
      let before = bounds
      let fetchInterval = parseInterval(
        DateKey.isoString(window.lowerBound)...DateKey.isoString(window.upperBound))
      switch await fetchSubRangeWarming(
        instrument: instrument, mapping: mapping, range: fetchInterval)
      {
      case .filled:
        filledAny = true
      case .cooledDown(let until):
        return .cooledDown(until: until)
      case .unavailable:
        break warmLoop
      }
      if boundsKeys(tokenId: tokenId) == before { break warmLoop }
    }
    if guardSteps >= 250 {
      logger.warning("warmRange: guard limit reached for \(tokenId, privacy: .public)")
    }
    return filledAny ? .filled : .unavailable
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

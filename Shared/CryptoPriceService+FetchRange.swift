// Shared/CryptoPriceService+FetchRange.swift

import Foundation

// MARK: - CryptoPriceService provider fallback

extension CryptoPriceService {
  /// Runs the provider fallback chain
  /// (CoinGecko → CryptoCompare → Binance) for the date enclosed by
  /// `dateString`, persists any new prices, and returns the requested
  /// day's value (or the prior-trading-day fallback). Throws a
  /// `WalletSyncError` attributed to the most recent *real* provider
  /// failure when no provider could fill the date — `noProviderMapping`
  /// errors are routing decisions (e.g. USDT has no Binance pair), not
  /// runtime failures, so they never become the attribution.
  func fetchAndExtendCache(
    instrument: Instrument,
    mapping: CryptoProviderMapping,
    fetchInterval: ClosedRange<Date>,
    dateString: String
  ) async throws -> Decimal {
    let tokenId = instrument.id
    let symbol = instrument.ticker ?? instrument.name
    var lastError: (any Error)?
    var lastProvider: SyncProvider?
    for client in clients {
      do {
        let fetched = try await client.dailyPrices(for: mapping, in: fetchInterval)
        if !fetched.isEmpty {
          let delta = mergeReturningDelta(
            tokenId: tokenId, symbol: symbol, newPrices: fetched)
          if !delta.isEmpty {
            try await persistDelta(tokenId: tokenId, deltaRecords: delta)
          }
          if let price = lookupPrice(tokenId: tokenId, dateString: dateString) {
            return price
          }
        }
      } catch is CancellationError {
        // Cooperative cancellation must surface as `CancellationError`, not
        // be wrapped into a provider outage — the coalescing owner cancels
        // this shared task and aggregation callers special-case cancellation.
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
    if let fallback = fallbackPrice(tokenId: tokenId, dateString: dateString) {
      return fallback
    }
    let underlyingDescription =
      lastError.map { String(describing: $0) }
      ?? String(
        describing: CryptoPriceError.noPriceAvailable(
          tokenId: tokenId, date: dateString))
    throw WalletSyncError(
      provider: lastProvider,
      kind: .network(underlyingDescription: underlyingDescription))
  }

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
        // into a provider outage. Mirrors `fetchAndExtendCache`.
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

  /// The sub-ranges of `range` not already covered by the token's cache.
  /// Mirrors the backward/forward extension decision in
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
      return [range.lowerBound...fetchUpperBound]  // cold cache: whole range
    }
    var result: [ClosedRange<Date>] = []
    if rangeStart < cache.earliestDate,
      let earliest = dateFormatter.date(from: cache.earliestDate),
      let backEnd = gregorian.date(byAdding: .day, value: -1, to: earliest),
      range.lowerBound <= backEnd
    {
      result.append(range.lowerBound...backEnd)
    }
    if fetchEndString > cache.latestDate,
      let forwardStart = dateFormatter.date(from: cache.latestDate),
      forwardStart <= fetchUpperBound
    {
      result.append(forwardStart...fetchUpperBound)
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

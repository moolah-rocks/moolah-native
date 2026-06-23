// Shared/CryptoPriceService+Warming.swift

import Foundation

// MARK: - Background warming

extension CryptoPriceService {
  /// Background-warm a token's prices over `range` using the same contiguous
  /// bounded-window loop as the shared engine's `coverRange`. Covers both endpoints,
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
    if !hydrated.contains(tokenId) {
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
    // Cover forward endpoint first, then backward — mirrors the shared engine's `coverRange`.
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

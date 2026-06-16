// Shared/CryptoPriceService+Live.swift

import Foundation

// MARK: - CryptoPriceService live (current) prices

// `currentPrices`: the live / spot endpoint — distinct from the historical daily
// bars handled in `CryptoPriceService.swift`'s `price(for:mapping:on:)`
// path. The result is intentionally not persisted via the cap-at-yesterday
// cache; `prefetchLatest` writes a single best-effort yesterday-tagged row
// and the next forward `dailyPrices` extension overwrites it.

extension CryptoPriceService {
  func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal] {
    var result: [String: Decimal] = [:]
    for client in clients {
      do {
        let prices = try await client.currentPrices(for: mappings)
        for (id, price) in prices where result[id] == nil {
          result[id] = price
        }
        if result.count == mappings.count { break }
      } catch {
        // Best-effort: try the next client. Log so a silent total miss
        // (all clients failed → empty dict) is diagnosable.
        logger.debug(
          "currentPrices: client \(type(of: client), privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
        )
        continue
      }
    }
    if result.isEmpty && !mappings.isEmpty {
      logger.warning("currentPrices: all clients failed; returning empty result")
    }
    return result
  }

  // MARK: - Prefetch

  func prefetchLatest(for registrations: [CryptoRegistration]) async {
    let mappings = registrations.map(\.mapping)
    let prices: [String: Decimal]
    do {
      prices = try await currentPrices(for: mappings)
    } catch {
      logger.warning(
        "Prefetch failed (best-effort): \(error.localizedDescription, privacy: .public)"
      )
      return
    }
    // Tag the live tick as the local-yesterday calendar day; see
    // `Shared/PriceCacheCap.swift`. The next forward `dailyPrices`
    // extension overwrites this best-effort value with the finalised
    // close.
    let dateString = dateFormatter.string(
      from: cappedToYesterday(now(), now: now, timeZone: timeZone))
    for (tokenId, price) in prices {
      let registration = registrations.first { $0.id == tokenId }
      let symbol = registration?.instrument.ticker ?? registration?.instrument.name ?? ""
      let delta = mergeReturningDelta(
        tokenId: tokenId, symbol: symbol, newPrices: [dateString: price])
      // Skip the disk write when the latest price is identical to the
      // already-cached value — periodic "no change" polling would
      // otherwise rewrite the partition on every tick.
      guard !delta.isEmpty else { continue }
      do {
        try await persistDelta(tokenId: tokenId, deltaRecords: delta)
      } catch {
        logger.warning(
          // Best-effort: continue the loop so a single bad token doesn't
          // poison the rest of the prefetch.
          "prefetchLatest: persistDelta failed for \(tokenId, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }
  }
}

// Shared/ExchangeRateService+Prefetch.swift

import Foundation
import GRDB

// MARK: - ExchangeRateService prefetch

// `prefetchLatest`: best-effort warm-up of the latest rates for a base instrument; called
// on app start / profile open. Targets the prior local-calendar day
// rather than today (see `Shared/PriceCacheCap.swift`) and overlaps the
// existing latest cached date by one day so a stale value gets
// re-validated.

extension ExchangeRateService {
  func prefetchLatest(base: Instrument) async {
    let code = base.id

    if !hydratedBases.contains(code) {
      do {
        try await loadCache(base: code)
      } catch {
        logger.warning(
          "prefetchLatest: loadCache failed for base \(code, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
    }

    let calendar = Calendar(identifier: .gregorian)
    let target = cappedToYesterday(now(), now: now, timeZone: timeZone)
    let targetString = dateFormatter.string(from: target)

    if let cache = caches[code], cache.latestDate >= targetString {
      return  // Already up to date
    }

    let fetchFrom: Date
    if let cache = caches[code],
      let latestDate = dateFormatter.date(from: cache.latestDate),
      latestDate <= target
    {
      fetchFrom = latestDate
    } else if let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: target) {
      fetchFrom = thirtyDaysAgo
    } else {
      fetchFrom = target
    }

    do {
      try await fetchAndMerge(base: code, from: fetchFrom, to: target)
    } catch {
      // Prefetch is best-effort — log so disk-write failures (which would
      // otherwise be conflated with expected network errors) are observable.
      logger.warning(
        "prefetchLatest: fetchAndMerge failed for base \(code, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}

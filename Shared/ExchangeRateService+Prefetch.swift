// Shared/ExchangeRateService+Prefetch.swift

import Foundation

// MARK: - ExchangeRateService prefetch

// `prefetchLatest`: best-effort warm-up of the latest rates for a base instrument; called
// on app start / profile open. Targets the prior local-calendar day
// rather than today (see `Shared/PriceCacheCap.swift`) and overlaps the
// existing latest cached date by one day so a stale value gets
// re-validated.

extension ExchangeRateService {
  func prefetchLatest(base: Instrument) async {
    let code = base.id

    // Hydrate + extend run under the per-base cache-extension gate so a
    // warm-up never interleaves with a concurrent `rate()` / `rates()`
    // fetch and union non-adjacent windows over an unfetched interior (see
    // `ExchangeRateService.cacheExtensionWaiters`).
    await withCacheExtension(base: code) {
      if !hydratedBases.contains(code) {
        do {
          try await loadCache(base: code)
        } catch {
          logger.warning(
            "prefetchLatest: loadCache failed for base \(code, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
      }

      let target = cappedToYesterday(now(), now: now, timeZone: timeZone)
      let targetString = dateFormatter.string(from: target)

      if let cache = caches[code], cache.latestDate >= targetString {
        return  // Already up to date
      }

      // Extend toward `target` using bounded 30-day windows driven by
      // `ContiguousFetchPlanner`. Uses the same fetch path as
      // `fetchToCoverDate` to keep cache bounds contiguous. Best-effort:
      // `fetchToCoverDate` only throws on cooperative cancellation, which is
      // benign here (prefetch is fire-and-forget); swallow it with `try?`.
      try? await fetchToCoverDate(base: code, date: target, dateString: targetString)
    }
  }
}

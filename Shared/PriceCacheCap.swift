// Shared/PriceCacheCap.swift

import Foundation

/// Clamps `date` to one calendar day before `now()` in `timeZone`.
///
/// All three price-cache services (FX rates, stock prices, crypto prices)
/// route same-day-as-now requests to the previous day so the cache only
/// ever stores finalised closes. Yahoo's `chart?interval=1d` endpoint
/// returns a partial bar for the still-running session whose `close` /
/// `adjclose` reflects the latest tick at the moment of the call;
/// persisting that as today's "close" then freezing it (cache hits never
/// re-fetch) was reproducing as VGS.AX showing a stale intraday print
/// even after the session settled.
///
/// "Yesterday" is computed in `timeZone` (production defaults to
/// `TimeZone.current`) so an AEDT user opening the app at 7am Tuesday
/// sees Monday's ASX close — a UTC-only cap would still be on Sunday at
/// that moment and miss Monday's 05:00 UTC settle, leaving prices a day
/// behind every morning. The returned `Date` is re-anchored to UTC noon
/// of the local-yesterday calendar day so:
///
///   1. The shared `ISO8601DateFormatter` (UTC) used as the cache key
///      formats the result to the same `YYYY-MM-DD` label the user
///      would call "yesterday".
///   2. The same `Date` passed to Yahoo / Frankfurter as the fetch upper
///      bound sits past local-morning market closes (e.g. ASX 05:00 UTC
///      for an AEDT user), so the requested session is included.
///
/// We never need a live price — the analysis panel and reports happily
/// use yesterday's close, and avoiding the same-day fetch keeps a fresh
/// cache run from immediately re-poisoning itself.
///
/// `now` and `timeZone` are both injectable so tests can pin them; the
/// production caller defaults `timeZone` to `.current`. Tests that
/// depend on a specific `YYYY-MM-DD` label must pass an explicit
/// `timeZone` (typically `UTC`) — otherwise the result varies with the
/// host's local zone. The fallback `return date` is unreachable in
/// practice (`Calendar.date(byAdding:value:to:)` only fails for
/// nonsensical inputs) but keeps the helper non-throwing.
func cappedToYesterday(
  _ date: Date,
  now: () -> Date,
  timeZone: TimeZone = .current
) -> Date {
  var local = Calendar(identifier: .gregorian)
  local.timeZone = timeZone
  let startOfTodayLocal = local.startOfDay(for: now())
  guard let yesterdayLocal = local.date(byAdding: .day, value: -1, to: startOfTodayLocal) else {
    return date
  }
  let components = local.dateComponents([.year, .month, .day], from: yesterdayLocal)
  var utc = Calendar(identifier: .gregorian)
  utc.timeZone = TimeZone(identifier: "UTC") ?? .current
  var noonComponents = components
  noonComponents.hour = 12
  noonComponents.minute = 0
  noonComponents.second = 0
  guard let yesterdayLabelAtUTCNoon = utc.date(from: noonComponents) else {
    return min(date, yesterdayLocal)
  }
  return min(date, yesterdayLabelAtUTCNoon)
}

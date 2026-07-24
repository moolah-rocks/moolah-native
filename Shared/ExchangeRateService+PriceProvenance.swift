import Foundation

extension ExchangeRateService {
  /// Effective daily reference-rate date used for a conversion. Resolves the
  /// rate first so the cache covers the request, then reports the exact or
  /// prior business day that actually supplied the quote.
  func effectiveRateDate(
    from: Instrument, to: Instrument, on date: Date
  ) async throws -> Date? {
    if from.id == to.id { return nil }
    _ = try await rate(from: from, to: to, on: date)
    let capped = cappedToYesterday(date, now: now, timeZone: timeZone)
    let dateString = dateFormatter.string(from: capped)
    guard
      let entry = fallbackRateEntry(
        base: from.id, quote: to.id, dateString: dateString),
      let effectiveDate = dateFormatter.date(from: DateKey.isoString(entry.key))
    else {
      throw ExchangeRateError.noRateAvailable(
        base: from.id, quote: to.id, date: dateString)
    }
    return effectiveDate
  }
}

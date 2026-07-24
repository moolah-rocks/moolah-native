import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("PriceDateDisclosureText", .serialized)
struct PriceDateDisclosureTests {
  @Test("market-day labels are invariant across device time zones")
  func marketDayLabelsAreZoneInvariant() throws {
    let originalTimeZone = NSTimeZone.default
    defer { NSTimeZone.default = originalTimeZone }
    let marketDay = try #require(
      Calendar.utc.date(from: DateComponents(year: 2025, month: 6, day: 12)))
    var compactLabels: Set<String> = []
    var fullLabels: Set<String> = []

    for identifier in [
      "America/Los_Angeles",
      "UTC",
      "Australia/Brisbane",
      "Pacific/Kiritimati",
    ] {
      NSTimeZone.default = try #require(TimeZone(identifier: identifier))
      let text = PriceDateDisclosureText(oldestDate: marketDay)
      compactLabels.insert(text.formattedDate)
      fullLabels.insert(text.fullDate)
    }

    #expect(compactLabels.count == 1)
    #expect(fullLabels.count == 1)
  }

  @Test("effective price and rate days are invariant across device time zones")
  func effectiveDateProducersAreZoneInvariant() async throws {
    let originalTimeZone = NSTimeZone.default
    defer { NSTimeZone.default = originalTimeZone }
    let requestedDay = try #require(
      Calendar.utc.date(from: DateComponents(year: 2025, month: 6, day: 15)))
    let expectedComponents = DateComponents(year: 2025, month: 6, day: 13)

    for identifier in [
      "America/Los_Angeles",
      "UTC",
      "Australia/Brisbane",
      "Pacific/Kiritimati",
    ] {
      let timeZone = try #require(TimeZone(identifier: identifier))
      NSTimeZone.default = timeZone

      let rateService = ExchangeRateService(
        client: FixedRateClient(rates: [
          "2025-06-13": ["AUD": dec("1.55")]
        ]),
        database: try ProfileIndexDatabase.openInMemory(),
        timeZone: timeZone)
      let rateDate = try #require(
        try await rateService.effectiveRateDate(
          from: .USD, to: .AUD, on: requestedDay))

      let stockService = StockPriceService(
        client: FixedStockPriceClient(responses: [
          "AAPL": StockPriceResponse(
            instrument: .USD,
            prices: ["2025-06-13": dec("185.50")])
        ]),
        database: try ProfileIndexDatabase.openInMemory(),
        timeZone: timeZone)
      let priceDate = try await stockService.effectivePriceDate(
        ticker: "AAPL", on: requestedDay)

      #expect(
        Calendar.utc.dateComponents([.year, .month, .day], from: rateDate)
          == expectedComponents)
      #expect(
        Calendar.utc.dateComponents([.year, .month, .day], from: priceDate)
          == expectedComponents)
    }
  }
}

import Foundation
import Testing

@testable import Moolah

/// Locks in Rule 5 of `guides/INSTRUMENT_CONVERSION_GUIDE.md` for the
/// legacy daily-balance pipeline: each (date, instrument) tuple must
/// be converted to the host currency on its own snapshot date, not on
/// today's rate.
///
/// `FakeConversionService.fixedRates` ignores its `on:` parameter, so it
/// cannot catch a regression that swaps `on: date` for `on: Date()`. These
/// tests use `FakeConversionService.dateRates` (rate keyed by date) so
/// a future refactor that drops the snapshot date fails loudly.
@Suite("InvestmentStore.aggregateDailyBalances conversion date")
@MainActor
struct InvestmentStoreDailyBalanceDateTests {
  private let aud = Instrument.AUD
  private let usd = Instrument.USD

  private func makeDate(year: Int, month: Int, day: Int) throws -> Date {
    try #require(
      Calendar(identifier: .gregorian).date(
        from: DateComponents(year: year, month: month, day: day)))
  }

  @Test("aggregates each date's USD balance using that date's rate, not today's")
  func usesSnapshotDateForConversion() async throws {
    let date1 = try makeDate(year: 2024, month: 1, day: 1)
    let date2 = try makeDate(year: 2024, month: 6, day: 1)

    let (backend, _) = try TestBackend.create(instrument: aud)
    let store = InvestmentStore(
      repository: backend.investments,
      conversionService: FakeConversionService.dateRates([
        date1: [usd.id: dec("1.5")],
        date2: [usd.id: dec("1.8")],
      ]))

    let raw = [
      AccountDailyBalance(
        date: date1,
        balance: InstrumentAmount(quantity: dec("100.00"), instrument: usd)),
      AccountDailyBalance(
        date: date2,
        balance: InstrumentAmount(quantity: dec("100.00"), instrument: usd)),
    ]

    let result = try await store.aggregateDailyBalances(
      raw: raw, hostCurrency: aud)

    // Forward-fill keeps the latest USD balance on each active date, then
    // converts at THAT date's rate: day1 = 100 USD * 1.5 = 150 AUD,
    // day2 = 100 USD * 1.8 = 180 AUD. A regression to "always use today's
    // rate" would produce two equal numbers.
    #expect(result.count == 2)
    #expect(result[0].date == date1)
    #expect(result[0].balance == InstrumentAmount(quantity: dec("150.00"), instrument: aud))
    #expect(result[1].date == date2)
    #expect(result[1].balance == InstrumentAmount(quantity: dec("180.00"), instrument: aud))
  }

  @Test("forward-filled USD balance on a later date converts at that later date's rate")
  func forwardFilledBalanceUsesLaterDateRate() async throws {
    let buyDate = try makeDate(year: 2024, month: 1, day: 1)
    let cashFlowDate = try makeDate(year: 2024, month: 6, day: 1)

    let (backend, _) = try TestBackend.create(instrument: aud)
    let store = InvestmentStore(
      repository: backend.investments,
      conversionService: FakeConversionService.dateRates([
        buyDate: [usd.id: dec("1.5")],
        cashFlowDate: [usd.id: dec("2.0")],
      ]))

    // USD balance only changes on day 1; day 2 has an AUD movement only.
    // Forward-fill keeps the 100 USD running on day 2, where it must be
    // converted at day 2's rate (2.0), not day 1's (1.5).
    let raw = [
      AccountDailyBalance(
        date: buyDate,
        balance: InstrumentAmount(quantity: dec("100.00"), instrument: usd)),
      AccountDailyBalance(
        date: cashFlowDate,
        balance: InstrumentAmount(quantity: dec("50.00"), instrument: aud)),
    ]

    let result = try await store.aggregateDailyBalances(
      raw: raw, hostCurrency: aud)

    #expect(result.count == 2)
    #expect(result[0].date == buyDate)
    // Day 1: 100 USD * 1.5 = 150 AUD.
    #expect(result[0].balance == InstrumentAmount(quantity: dec("150.00"), instrument: aud))
    #expect(result[1].date == cashFlowDate)
    // Day 2: 100 USD * 2.0 + 50 AUD = 250 AUD. A regression that uses
    // `Date()` instead of `date` for the USD leg's conversion would
    // produce a different number on this date (likely a 1:1 fallback
    // since `Date()` is not in the rate table).
    #expect(result[1].balance == InstrumentAmount(quantity: dec("250.00"), instrument: aud))
  }
}

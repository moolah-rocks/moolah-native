import Foundation
import Testing

@testable import Moolah

/// Verifies that host-currency (cash) legs are included in the value series
/// after the fix to `PositionsHistoryBuilder.apply`. Before the fix the
/// `where leg.instrument != hostCurrency` guard excluded AUD legs from
/// `state.quantities`, leaving pure-fiat accounts with an empty chart and
/// mixed fiat+crypto accounts under-reporting their total value.
@Suite
struct PositionsHistoryBuilderCashTests {
  let aud = Instrument.AUD
  let accountId = UUID()

  /// Day 0 = 2026-01-01 UTC midnight. Uses `Calendar.utc` so dates are zone-invariant.
  private func date(daysAfterEpoch days: Int) -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 1
    components.day = 1 + days
    guard let result = Calendar.utc.date(from: components) else {
      fatalError("Could not construct date \(days) days after 2026-01-01")
    }
    return result
  }

  /// A pure-fiat (AUD-only) account must produce a running-balance value
  /// line once host-currency legs are included in the quantity fold.
  /// Before the fix, AUD legs were excluded from `state.quantities` so
  /// the total series was empty for this account type.
  @Test
  func pureFiatAccountProducesRunningBalanceLine() async throws {
    // Arrange: two AUD income deposits on consecutive days.
    // A second participant UUID acts as the external counterpart so
    // AccountCashFlows.flowAmounts sees a boundary-crossing transaction.
    let externalId = UUID()
    let deposit1 = Transaction(
      date: date(daysAfterEpoch: 0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 1_000, type: .income),
        TransactionLeg(
          accountId: externalId, instrument: aud, quantity: -1_000, type: .expense),
      ])
    let deposit2 = Transaction(
      date: date(daysAfterEpoch: 1),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 500, type: .income),
        TransactionLeg(
          accountId: externalId, instrument: aud, quantity: -500, type: .expense),
      ])

    // AUD→AUD uses the identity conversion fast-path; no rates needed.
    let service = FakeConversionService.fixedRates([:])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let now = date(daysAfterEpoch: 5)

    let series = await builder.build(
      transactions: [deposit1, deposit2],
      accountId: accountId,
      hostCurrency: aud,
      range: .oneMonth,
      now: now)

    // Six points span days 0..5: start = firstTxnDate = day 0, endDay = day 5.
    // Before the fix, all AUD legs were excluded → totalSeries was empty.
    #expect(series.totalSeries.count == 6)

    // Day 0: balance = 1_000 (first deposit only).
    let day0 = try #require(
      series.totalSeries.first {
        Calendar.utc.startOfDay(for: $0.date) == date(daysAfterEpoch: 0)
      })
    #expect(day0.value == 1_000)

    // Day 1 onwards: balance = 1_500 (both deposits cumulated).
    let day1 = try #require(
      series.totalSeries.first {
        Calendar.utc.startOfDay(for: $0.date) == date(daysAfterEpoch: 1)
      })
    #expect(day1.value == 1_500)
    #expect(series.totalSeries.last?.value == 1_500)
  }

  /// A mixed fiat+crypto account must include the AUD cash balance in its
  /// total value. Before the fix, the host-currency (AUD) leg was excluded
  /// and the total reflected only the non-cash instrument value.
  @Test
  func mixedFiatAndCryptoIncludesCashInTotal() async throws {
    // Arrange: AUD account holding 8 ETH (priced at 3_000 AUD each) and
    // 2_000 AUD cash, both received on day 0.
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let externalId = UUID()

    let receiveEth = Transaction(
      date: date(daysAfterEpoch: 0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: eth, quantity: 8, type: .income),
        TransactionLeg(
          accountId: externalId, instrument: eth, quantity: -8, type: .expense),
      ])
    let depositAud = Transaction(
      date: date(daysAfterEpoch: 0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 2_000, type: .income),
        TransactionLeg(
          accountId: externalId, instrument: aud, quantity: -2_000, type: .expense),
      ])

    let service = FakeConversionService.fixedRates([eth.id: Decimal(3_000)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let now = date(daysAfterEpoch: 3)

    let series = await builder.build(
      transactions: [receiveEth, depositAud],
      accountId: accountId,
      hostCurrency: aud,
      range: .oneMonth,
      now: now)

    // Total = 8 × 3_000 (ETH) + 2_000 (AUD cash) = 26_000.
    // Before the fix the AUD leg was excluded, giving 24_000 (ETH only).
    let last = try #require(series.totalSeries.last)
    #expect(last.value == 8 * Decimal(3_000) + 2_000)
  }
}

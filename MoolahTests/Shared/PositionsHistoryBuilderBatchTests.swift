import Foundation
import Testing

@testable import Moolah

@Suite("PositionsHistoryBuilder batch")
struct PositionsHistoryBuilderBatchTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")
  let accountId = UUID()

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

  private func buy(
    instrument: Instrument, qty: Decimal, fiat: Decimal, daysAfterEpoch days: Int
  ) -> Transaction {
    Transaction(
      date: date(daysAfterEpoch: days),
      legs: [
        TransactionLeg(accountId: accountId, instrument: instrument, quantity: qty, type: .trade),
        TransactionLeg(accountId: accountId, instrument: aud, quantity: -fiat, type: .trade),
      ])
  }

  @Test("build issues exactly one batch covering every held (instrument, day) pair")
  func singleBatch() async {
    // BHP held days 1..5 (5 pts) + CBA held days 2..5 (4 pts) = 9 value requests.
    let txns = [
      buy(instrument: bhp, qty: 100, fiat: 4_000, daysAfterEpoch: 1),
      buy(instrument: cba, qty: 50, fiat: 5_000, daysAfterEpoch: 2),
    ]
    let service = FakeConversionService.fixedRates([bhp.id: Decimal(50), cba.id: Decimal(110)])
    let builder = PositionsHistoryBuilder(conversionService: service)
    _ = await builder.build(
      transactions: txns, accountId: accountId, hostCurrency: aud,
      range: .oneMonth, now: date(daysAfterEpoch: 5))
    // Exactly one flat batch, not N serial convertResult hops.
    #expect(service.recordedBatches.count == 1)
    #expect(service.recordedBatches.first?.count == 9)
  }

  @Test("knownZero instrument contributes 0 and keeps the day's aggregate")
  func knownZeroContributesZeroKeepsAggregate() async throws {
    // BHP priced, CBA resolves knownZero (spam/unpriced/pre-first-trade analogue).
    let txns = [
      buy(instrument: bhp, qty: 100, fiat: 4_000, daysAfterEpoch: 1),
      buy(instrument: cba, qty: 50, fiat: 5_000, daysAfterEpoch: 2),
    ]
    let service = FakeConversionService.fixedRates(
      [bhp.id: Decimal(50)], knownZero: [cba.id])
    let builder = PositionsHistoryBuilder(conversionService: service)
    let series = await builder.build(
      transactions: txns, accountId: accountId, hostCurrency: aud,
      range: .threeMonths, now: date(daysAfterEpoch: 5))
    // Aggregate kept on every day (unlike a .failure which would drop days ≥ 2):
    // days 1..5 all have a total point.
    #expect(series.totalSeries.count == 5)
    // Day 5 total = BHP 100×50 + CBA 0 = 5000.
    #expect(series.totalSeries.last?.value == 100 * Decimal(50))
  }
}

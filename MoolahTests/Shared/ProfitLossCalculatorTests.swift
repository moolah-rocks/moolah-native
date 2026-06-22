import Foundation
import Testing

@testable import Moolah

@Suite("ProfitLossCalculator")
struct ProfitLossCalculatorTests {
  let aud = Instrument.fiat(code: "AUD")

  private func stockInstrument(_ name: String) -> Instrument {
    Instrument.stock(ticker: "\(name).AX", exchange: "ASX", name: name)
  }

  private func date(_ daysFromBase: Int) -> Date {
    let calendar = Calendar(identifier: .gregorian)
    guard
      let base = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)),
      let result = calendar.date(byAdding: .day, value: daysFromBase, to: base)
    else {
      fatalError("Could not construct date \(daysFromBase) days from 2024-01-01")
    }
    return result
  }

  @Test
  func singleInstrument_noSales_unrealizedOnly() async throws {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    // BHP now worth $50/share
    let service = FakeConversionService.fixedRates(["ASX:BHP.AX": 50])
    let results = try await ProfitLossCalculator.compute(
      transactions: [buyTx],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: date(365)
    )

    #expect(results.count == 1)
    let bhpPL = results[0]
    #expect(bhpPL.instrument.id == "ASX:BHP.AX")
    #expect(bhpPL.totalInvested == 4000)
    #expect(bhpPL.currentValue == 5000)
    #expect(bhpPL.unrealizedGain == 1000)
    #expect(bhpPL.realizedGain == 0)
    #expect(bhpPL.currentQuantity == 100)
  }

  @Test
  func partialSale_showsBothRealizedAndUnrealized() async throws {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let sellTx = LegTransaction(
      date: date(200),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -50, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 3000, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    // BHP now worth $50/share
    let service = FakeConversionService.fixedRates(["ASX:BHP.AX": 50])
    let results = try await ProfitLossCalculator.compute(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: date(365)
    )

    #expect(results.count == 1)
    let bhpPL = results[0]
    #expect(bhpPL.currentQuantity == 50)
    #expect(bhpPL.totalInvested == 4000)
    #expect(bhpPL.currentValue == 2500)
    #expect(bhpPL.realizedGain == 1000)
    // Remaining cost basis: 50 * 40 = 2000. Current value: 2500. Unrealized: 500.
    #expect(bhpPL.unrealizedGain == 500)
  }

  @Test
  func fullySold_onlyRealizedGain() async throws {
    let bhp = stockInstrument("BHP")
    let accountId = UUID()

    let buyTx = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -4000, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: 100, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let sellTx = LegTransaction(
      date: date(200),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: bhp, quantity: -100, type: .trade,
          categoryId: nil, earmarkId: nil),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 5000, type: .trade,
          categoryId: nil, earmarkId: nil),
      ])

    let service = FakeConversionService.fixedRates([:])
    let results = try await ProfitLossCalculator.compute(
      transactions: [buyTx, sellTx],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: date(365)
    )

    // Fully sold instruments should still appear (realized gain exists)
    #expect(results.count == 1)
    #expect(results[0].currentQuantity == 0)
    #expect(results[0].currentValue == 0)
    #expect(results[0].unrealizedGain == 0)
    #expect(results[0].realizedGain == 1000)
  }

  @Test
  func fiatOnlyTransactions_excludedFromResults() async throws {
    let accountId = UUID()
    let transaction = LegTransaction(
      date: date(0),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -500, type: .expense,
          categoryId: nil, earmarkId: nil)
      ])

    let service = FakeConversionService.fixedRates([:])
    let results = try await ProfitLossCalculator.compute(
      transactions: [transaction],
      profileCurrency: aud,
      conversionService: service,
      asOfDate: date(0)
    )
    #expect(results.isEmpty)
  }

  // MARK: - Multi-instrument portfolios
}

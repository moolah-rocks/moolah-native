import Foundation
import Testing

@testable import Moolah

@Suite("AccountPerformanceCalculator.compute")
struct AccountPerformanceCalculatorTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")

  /// Fixture: account opened with $10,000 exactly one year before `now`,
  /// terminal value $11,000.
  private struct OpeningBalanceFixture {
    let accountId = UUID()
    let openingDate = Date(timeIntervalSinceReferenceDate: 0)
    var now: Date { openingDate.addingTimeInterval(365 * 86_400) }
    let transactions: [Transaction]
    let valued: [ValuedPosition]

    init(aud: Instrument) {
      let accountId = self.accountId
      transactions = [
        Transaction(
          date: openingDate,
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: aud, quantity: 10_000, type: .openingBalance)
          ]
        )
      ]
      valued = [
        ValuedPosition(
          instrument: aud, quantity: 11_000,
          unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 11_000, instrument: aud))
      ]
    }
  }

  @Test("opening balance with growth records contributions, P/L, and first flow date")
  func openingBalanceContributionsAndProfitLoss() async throws {
    let fixture = OpeningBalanceFixture(aud: aud)
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: fixture.accountId,
      transactions: fixture.transactions,
      valuedPositions: fixture.valued,
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]),
      now: fixture.now
    )
    #expect(perf.currentValue == InstrumentAmount(quantity: 11_000, instrument: aud))
    #expect(perf.totalContributions == InstrumentAmount(quantity: 10_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 1_000, instrument: aud))
    #expect(perf.firstFlowDate == fixture.openingDate)
  }

  @Test("opening balance with 10 percent growth records 10 percent Modified Dietz return")
  func openingBalanceModifiedDietzPercent() async throws {
    let fixture = OpeningBalanceFixture(aud: aud)
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: fixture.accountId,
      transactions: fixture.transactions,
      valuedPositions: fixture.valued,
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]),
      now: fixture.now
    )
    let percent = try #require(perf.profitLossPercent)
    // Modified Dietz with one flow at t=0 and weighted-capital == ΣC = 10_000
    // is exactly (V − ΣC) / ΣC = 1000 / 10000 = 0.1.
    #expect(percent == Decimal(1) / Decimal(10))
  }

  @Test("opening balance with 10 percent growth converges on 10 percent annualised")
  func openingBalanceAnnualisedReturn() async throws {
    let fixture = OpeningBalanceFixture(aud: aud)
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: fixture.accountId,
      transactions: fixture.transactions,
      valuedPositions: fixture.valued,
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]),
      now: fixture.now
    )
    let annualised = try #require(perf.annualisedReturn)
    let asDouble = Double(truncating: annualised as NSDecimalNumber)
    #expect(abs(asDouble - 0.10) < 0.001, "expected ~0.10, got \(asDouble)")
  }

  /// A two-leg trade in the same account → no boundary crossed → no flow.
  /// With zero contributions the calculator reports the entire V_now as
  /// P/L — this is the "free value" case for an account with only
  /// intra-account activity, which has no contribution baseline against
  /// which to subtract.
  @Test("intra-account trade does not produce a cash flow")
  func intraAccountTradeNoFlow() async throws {
    let accountId = UUID()
    let openingDate = Date(timeIntervalSinceReferenceDate: 0)
    let now = openingDate.addingTimeInterval(365 * 86_400)
    let trade = Transaction(
      date: openingDate,
      legs: [
        TransactionLeg(accountId: accountId, instrument: bhp, quantity: 100, type: .trade),
        TransactionLeg(accountId: accountId, instrument: aud, quantity: -4_000, type: .trade),
      ]
    )
    let valued = [
      ValuedPosition(
        instrument: bhp, quantity: 100, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 5_000, instrument: aud))
    ]
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: accountId,
      transactions: [trade],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]),
      now: now
    )
    #expect(perf.totalContributions == InstrumentAmount(quantity: 0, instrument: aud))
    #expect(perf.firstFlowDate == nil)
    // V_now = 5,000, contributions = 0 → P/L = 5,000.
    // No external flows means the entire current value is reported as gain
    // — the "free value" case for accounts with only intra-account activity.
    #expect(perf.profitLoss == InstrumentAmount(quantity: 5_000, instrument: aud))
  }

  /// A `.transfer` leg pair across two accounts → boundary crossed → flow
  /// recorded on the investment account's side. (The cash account's side
  /// would mirror this — confirmed by symmetry of the boundary-crossing
  /// rule, not by a separate test fixture.)
  @Test("cross-account transfer produces a cash flow")
  func crossAccountTransferFlow() async throws {
    let investmentAccount = UUID()
    let cashAccount = UUID()
    let openingDate = Date(timeIntervalSinceReferenceDate: 0)
    let now = openingDate.addingTimeInterval(365 * 86_400)
    let transfer = Transaction(
      date: openingDate,
      legs: [
        TransactionLeg(
          accountId: cashAccount, instrument: aud, quantity: -1_000, type: .transfer),
        TransactionLeg(
          accountId: investmentAccount, instrument: aud, quantity: 1_000, type: .transfer),
      ]
    )
    let valued = [
      ValuedPosition(
        instrument: aud, quantity: 1_100, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 1_100, instrument: aud))
    ]
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: investmentAccount,
      transactions: [transfer],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]),
      now: now
    )
    #expect(perf.totalContributions == InstrumentAmount(quantity: 1_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 100, instrument: aud))
    #expect(perf.firstFlowDate == openingDate)
  }

  /// A standalone `.income` leg (e.g. dividend paid in cash) is single-
  /// account, no boundary → no flow. The cash sits in the account, lifting
  /// V_now and so showing up in P/L as a gain.
  @Test("standalone income leg does not produce a cash flow")
  func dividendNoFlow() async throws {
    let accountId = UUID()
    let openingDate = Date(timeIntervalSinceReferenceDate: 0)
    let now = openingDate.addingTimeInterval(365 * 86_400)
    let dividend = Transaction(
      date: openingDate,
      legs: [
        TransactionLeg(accountId: accountId, instrument: aud, quantity: 50, type: .income)
      ]
    )
    let valued = [
      ValuedPosition(
        instrument: aud, quantity: 50, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 50, instrument: aud))
    ]
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: accountId,
      transactions: [dividend],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]),
      now: now
    )
    #expect(perf.totalContributions == InstrumentAmount(quantity: 0, instrument: aud))
    #expect(perf.firstFlowDate == nil)
    // Standalone .income with no flows is the same "free value" case as
    // intra-account trade — P/L = currentValue − 0 = 50.
    #expect(perf.profitLoss == InstrumentAmount(quantity: 50, instrument: aud))
  }

  /// Conversion-failure path: the calculator throws so the caller can mark
  /// the whole performance unavailable. Per Rule 11, no partial sums.
  @Test("conversion failure on a flow propagates as a throw")
  func conversionFailureOnFlowThrows() async throws {
    let accountId = UUID()
    let cashAccount = UUID()
    let usd = Instrument.USD
    let openingDate = Date(timeIntervalSinceReferenceDate: 0)
    let now = openingDate.addingTimeInterval(365 * 86_400)
    let txn = Transaction(
      date: openingDate,
      legs: [
        TransactionLeg(accountId: cashAccount, instrument: usd, quantity: -100, type: .transfer),
        TransactionLeg(accountId: accountId, instrument: usd, quantity: 100, type: .transfer),
      ]
    )
    let conversion = FakeConversionService.failingInstruments([usd.id])
    let valued = [
      ValuedPosition(
        instrument: usd, quantity: 100, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 150, instrument: aud))
    ]
    await #expect(throws: FakeConversionError.self) {
      _ = try await AccountPerformanceCalculator.compute(
        accountId: accountId,
        transactions: [txn],
        valuedPositions: valued,
        profileCurrency: aud,
        conversionService: conversion,
        now: now)
    }
  }

  /// V_now unavailable (any position's `value` is `nil`) → calculator
  /// returns a partial `AccountPerformance` with `currentValue`,
  /// `profitLoss`, `profitLossPercent`, and `annualisedReturn` all nil
  /// (they all require V), but `totalContributions` and `firstFlowDate`
  /// stay populated from the successfully-extracted flows. Matches the
  /// design's §3 edge-case Row 6.
  @Test("missing position value yields unavailable performance")
  func unavailableValueYieldsUnavailablePerformance() async throws {
    let accountId = UUID()
    let openingDate = Date(timeIntervalSinceReferenceDate: 0)
    let now = openingDate.addingTimeInterval(365 * 86_400)
    let opening = Transaction(
      date: openingDate,
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 1_000, type: .openingBalance)
      ]
    )
    let valued = [
      ValuedPosition(
        instrument: aud, quantity: 1_000, unitPrice: nil, costBasis: nil, value: nil)
    ]
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: accountId,
      transactions: [opening],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]),
      now: now
    )
    #expect(perf.currentValue == nil)
    #expect(perf.totalContributions == InstrumentAmount(quantity: 1_000, instrument: aud))
    #expect(perf.profitLoss == nil)
    #expect(perf.profitLossPercent == nil)
    #expect(perf.annualisedReturn == nil)
    #expect(perf.firstFlowDate == openingDate)
  }
}

import Foundation
import Testing

@testable import Moolah

/// Edge-case rows from the §3 design table — each pinned in its own
/// test so a regression on Row N reads as a single named failure.
@Suite("AccountPerformanceCalculator.compute edge cases")
struct AccountPerformanceEdgeCaseTests {
  let aud = Instrument.AUD

  /// Row 1 of the §3 edge-case table: empty account (no transactions,
  /// no positions). Matches the V=0, no-flows row.
  @Test("empty account with no flows reports all zeros and nil percentages")
  func emptyAccountNoFlows() async throws {
    let accountId = UUID()
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: accountId,
      transactions: [],
      valuedPositions: [],
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:])
    )
    #expect(perf.currentValue == InstrumentAmount(quantity: 0, instrument: aud))
    #expect(perf.totalContributions == InstrumentAmount(quantity: 0, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 0, instrument: aud))
    #expect(perf.profitLossPercent == nil)
    #expect(perf.annualisedReturn == nil)
    #expect(perf.firstFlowDate == nil)
  }

  /// Row 2 of the §3 edge-case table: single deposit, no trades, no
  /// growth. P/L = 0; Modified Dietz % = 0; annualised = 0.
  @Test("single deposit with no growth reports zero P/L, zero percent, zero annualised")
  func singleDepositNoGrowth() async throws {
    let accountId = UUID()
    let openingDate = Date(timeIntervalSinceReferenceDate: 0)
    let now = openingDate.addingTimeInterval(365 * 86_400)
    let opening = Transaction(
      date: openingDate,
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 10_000, type: .openingBalance)
      ]
    )
    let valued = [
      ValuedPosition(
        instrument: aud, quantity: 10_000,
        unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 10_000, instrument: aud))
    ]
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: accountId,
      transactions: [opening],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]),
      now: now
    )
    #expect(perf.currentValue == InstrumentAmount(quantity: 10_000, instrument: aud))
    #expect(perf.totalContributions == InstrumentAmount(quantity: 10_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 0, instrument: aud))
    let pct = try #require(perf.profitLossPercent)
    #expect(pct == 0)
    let annualised = try #require(perf.annualisedReturn)
    let asDouble = Double(truncating: annualised as NSDecimalNumber)
    #expect(abs(asDouble) < 0.001, "expected ~0 p.a., got \(asDouble)")
  }

  /// Row 3 of the §3 edge-case table: deposit then full withdrawal one
  /// year later, V=0. ΣC = 0; weighted-capital is positive (deposit was
  /// in for the full year, withdrawal cancels late) so Modified Dietz %
  /// converges on 0. Annualised return — IRR of {+1000 at t=0,
  /// -1000 at t=365, V=0 at t=365} converges on 0.
  @Test("deposit then full withdrawal yields zero contributions and zero P/L")
  func depositThenFullWithdrawal() async throws {
    let accountId = UUID()
    let cashAccount = UUID()
    let depositDate = Date(timeIntervalSinceReferenceDate: 0)
    let withdrawalDate = depositDate.addingTimeInterval(365 * 86_400)
    let deposit = Transaction(
      date: depositDate,
      legs: [
        TransactionLeg(
          accountId: cashAccount, instrument: aud, quantity: -1_000, type: .transfer),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 1_000, type: .transfer),
      ]
    )
    let withdrawal = Transaction(
      date: withdrawalDate,
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: -1_000, type: .transfer),
        TransactionLeg(
          accountId: cashAccount, instrument: aud, quantity: 1_000, type: .transfer),
      ]
    )
    let valued = [
      ValuedPosition(
        instrument: aud, quantity: 0,
        unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 0, instrument: aud))
    ]
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: accountId,
      transactions: [deposit, withdrawal],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]),
      now: withdrawalDate
    )
    #expect(perf.currentValue == InstrumentAmount(quantity: 0, instrument: aud))
    #expect(perf.totalContributions == InstrumentAmount(quantity: 0, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 0, instrument: aud))
    #expect(perf.firstFlowDate == depositDate)
  }

  /// Row 4 of the §3 edge-case table: first flow less than one day
  /// before now. currentValue / totalContributions / profitLoss are all
  /// populated, but profitLossPercent and annualisedReturn are nil
  /// because the time span is too short to report a meaningful rate.
  @Test("first flow under one day old marks percentages unavailable")
  func firstFlowSubDaySpan() async throws {
    let accountId = UUID()
    let firstFlowDate = Date(timeIntervalSinceReferenceDate: 0)
    let now = firstFlowDate.addingTimeInterval(60 * 60)  // one hour later
    let opening = Transaction(
      date: firstFlowDate,
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 1_000, type: .openingBalance)
      ]
    )
    let valued = [
      ValuedPosition(
        instrument: aud, quantity: 1_000,
        unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 1_010, instrument: aud))
    ]
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: accountId,
      transactions: [opening],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]),
      now: now
    )
    #expect(perf.currentValue == InstrumentAmount(quantity: 1_010, instrument: aud))
    #expect(perf.totalContributions == InstrumentAmount(quantity: 1_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 10, instrument: aud))
    #expect(perf.profitLossPercent == nil)
    #expect(perf.annualisedReturn == nil)
  }
}

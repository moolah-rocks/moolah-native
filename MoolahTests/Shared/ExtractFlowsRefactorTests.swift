import Foundation
import Testing

@testable import Moolah

/// Regression coverage for the
/// `AccountCashFlows.flowAmounts(for:)` extraction in
/// `AccountPerformanceCalculator.extractFlows`. Lives in its own
/// file because `AccountPerformanceCalculatorTests` was already at
/// the SwiftLint type-body-length limit.
@Suite("AccountPerformanceCalculator extractFlows refactor")
struct ExtractFlowsRefactorTests {
  let aud = Instrument.AUD

  /// Locks in the per-leg `CashFlow` summation across the
  /// `AccountCashFlows.flowAmounts(for:)` refactor. Modified Dietz /
  /// IRR weighting is invariant to leg order within the same date,
  /// but the `totalContributions` sum is not — a refactor that
  /// silently dropped a leg or applied the boundary-crossing rule
  /// at a different granularity would slip past the existing suite.
  @Test("extractFlows preserves per-leg contributions across a multi-leg transaction")
  func extractFlowsPreservesLegContributions() async throws {
    let accountId = UUID()
    let txn = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 100,
          type: .openingBalance),
        TransactionLeg(
          accountId: accountId, instrument: aud, quantity: 200,
          type: .openingBalance),
      ]
    )
    let valued = [
      ValuedPosition(
        instrument: aud, quantity: 300, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 300, instrument: aud))
    ]
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: accountId,
      transactions: [txn],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:])
    )
    #expect(
      perf.totalContributions == InstrumentAmount(quantity: 300, instrument: aud)
    )
    #expect(perf.firstFlowDate == txn.date)
  }

  /// Locks in conversion-on-`transaction.date` at the calculator
  /// integration level. The helper already covers this in isolation
  /// (`AccountCashFlowsTests.openingBalanceForeignCurrencyLegUsesTxnDate`),
  /// but a regression that wired the calculator to `Date()` while
  /// the helper kept `transaction.date` would slip past helper-level
  /// tests alone.
  @Test("extractFlows converts foreign-currency contributions on transaction.date")
  func extractFlowsConvertsOnTransactionDate() async throws {
    let usd = Instrument.USD
    let accountId = UUID()
    let txnDate = Date(timeIntervalSince1970: 1_700_000_000)
    let nowDate = Date(timeIntervalSince1970: 1_800_000_000)
    let txnRate = try #require(Decimal(string: "1.50"))
    let nowRate = try #require(Decimal(string: "1.40"))
    let service = FakeConversionService.dateRates([
      txnDate: [usd.id: txnRate],
      nowDate: [usd.id: nowRate],
    ])
    let txn = Transaction(
      date: txnDate,
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: usd, quantity: 100,
          type: .openingBalance)
      ]
    )
    let valued = [
      ValuedPosition(
        instrument: aud, quantity: 200, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 200, instrument: aud))
    ]
    let perf = try await AccountPerformanceCalculator.compute(
      accountId: accountId,
      transactions: [txn],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: service,
      now: nowDate
    )
    // 100 USD × 1.50 (txnDate rate) — a Date()-ish regression would
    // pick the 1.40 nowDate rate and produce 140.
    #expect(
      perf.totalContributions == InstrumentAmount(quantity: 150, instrument: aud)
    )
  }
}

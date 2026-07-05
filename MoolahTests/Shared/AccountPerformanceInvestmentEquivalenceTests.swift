import Foundation
import Testing

@testable import Moolah

// swiftlint:disable type_name
@Suite("AccountPerformance — investment path equivalence")
struct AccountPerformanceInvestmentEquivalenceTests {
  // swiftlint:enable type_name
  let aud = Instrument.AUD

  /// A normally-funded investment account (opening balance is an external
  /// flow) yields identical performance from the legacy single-account
  /// `compute` and the unified `computeMultiInstrument([id])`. Locks the fold:
  /// routing investment through the shared modifier does not change the tiles.
  @Test("funded investment account: single-account and multi-instrument agree")
  func fundedAccountAgrees() async throws {
    let account = UUID()
    let openingDate = Date(timeIntervalSinceReferenceDate: 0)
    let now = openingDate.addingTimeInterval(365 * 86_400)
    let opening = Transaction(
      date: openingDate,
      legs: [
        TransactionLeg(accountId: account, instrument: aud, quantity: 1_000, type: .openingBalance)
      ])
    let valued = [
      ValuedPosition(
        instrument: aud, quantity: 1_200, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 1_200, instrument: aud))
    ]
    let service = FakeConversionService.fixedRates([:])
    let single = try await AccountPerformanceCalculator.compute(
      accountId: account, transactions: [opening], valuedPositions: valued,
      profileCurrency: aud, conversionService: service, now: now)
    let multi = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [account], transactions: [opening], valuedPositions: valued,
      profileCurrency: aud, conversionService: service, now: now)
    #expect(single.currentValue == multi.currentValue)
    #expect(single.totalContributions == multi.totalContributions)
    #expect(single.profitLoss == multi.profitLoss)
    #expect(single.profitLossPercent == multi.profitLossPercent)
    #expect(single.annualisedReturn == multi.annualisedReturn)
    #expect(single.firstFlowDate == multi.firstFlowDate)
  }

  /// The one intentional divergence: an account funded solely by
  /// single-account income (no opening balance, no transfer-in) has no
  /// external flows. Legacy `compute` paints the whole value as gain;
  /// the unified path degrades to current-value-only (Rule 11: no phantom
  /// gain). The fold accepts the latter.
  @Test("no-external-flow account: unified path degrades to current value only")
  func noFlowDivergence() async throws {
    let account = UUID()
    let date = Date(timeIntervalSinceReferenceDate: 0)
    let income = Transaction(
      date: date,
      legs: [TransactionLeg(accountId: account, instrument: aud, quantity: 500, type: .income)])
    let valued = [
      ValuedPosition(
        instrument: aud, quantity: 500, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 500, instrument: aud))
    ]
    let service = FakeConversionService.fixedRates([:])
    let now = date.addingTimeInterval(30 * 86_400)
    let single = try await AccountPerformanceCalculator.compute(
      accountId: account, transactions: [income], valuedPositions: valued,
      profileCurrency: aud, conversionService: service, now: now)
    let multi = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [account], transactions: [income], valuedPositions: valued,
      profileCurrency: aud, conversionService: service, now: now)
    #expect(single.profitLoss == InstrumentAmount(quantity: 500, instrument: aud))
    #expect(multi.profitLoss == nil)
    #expect(multi.currentValue == InstrumentAmount(quantity: 500, instrument: aud))
    #expect(multi.totalContributions == nil)
    #expect(multi.profitLossPercent == nil)
    #expect(multi.annualisedReturn == nil)
    #expect(multi.firstFlowDate == nil)
  }
}

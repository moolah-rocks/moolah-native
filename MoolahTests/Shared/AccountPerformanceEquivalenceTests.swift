import Foundation
import Testing

@testable import Moolah

@Suite("AccountPerformance — investment path equivalence")
struct AccountPerformanceEquivalenceTests {
  private let aud = Instrument.AUD
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)

  private func day(_ n: Int) -> Date { Date(timeIntervalSinceReferenceDate: Double(n) * 86_400) }

  private func leg(
    _ account: UUID, _ i: Instrument, _ qty: Decimal, _ type: TransactionType
  ) -> TransactionLeg {
    TransactionLeg(accountId: account, instrument: i, quantity: qty, type: type)
  }

  private func valued(_ i: Instrument, quantity: Decimal, worth: Decimal) -> ValuedPosition {
    ValuedPosition(
      instrument: i, quantity: quantity, unitPrice: nil, costBasis: nil,
      value: InstrumentAmount(quantity: worth, instrument: aud))
  }

  private func buildLedger(
    _ txns: [Transaction], rates: [String: Decimal] = [:]
  ) async throws -> HoldingsCostLedger {
    try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates(rates))
  }

  private func expectAgreement(_ single: AccountPerformance, _ multi: AccountPerformance) {
    #expect(single.currentValue == multi.currentValue)
    #expect(single.amountInvested == multi.amountInvested)
    #expect(single.profitLoss == multi.profitLoss)
    #expect(single.profitLossPercent == multi.profitLossPercent)
    #expect(single.annualisedReturn == multi.annualisedReturn)
    #expect(single.firstFlowDate == multi.firstFlowDate)
  }

  /// A bought-position account yields identical performance from the
  /// single-account `compute` and the unified `computeMultiInstrument([id])`.
  /// Both now read the same ledger surfaces, so they cannot diverge.
  @Test("bought-position account: single-account and multi-instrument agree")
  func boughtPositionAgrees() async throws {
    let account = UUID()
    let buy = Transaction(
      date: day(0), legs: [leg(account, aud, -1_000, .trade), leg(account, eth, 1, .trade)])
    let ledger = try await buildLedger([buy])
    let rows = [valued(eth, quantity: 1, worth: 1_200)]
    let single = try await AccountPerformanceCalculator.compute(
      accountId: account, valuedPositions: rows, profileCurrency: aud, ledger: ledger, now: day(365)
    )
    let multi = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [account], valuedPositions: rows, profileCurrency: aud, ledger: ledger,
      now: day(365))
    expectAgreement(single, multi)
    #expect(single.amountInvested == InstrumentAmount(quantity: 1_000, instrument: aud))
  }

  /// A receive-only wallet: the two entry points still agree. The old model's
  /// deliberate divergence (single painted the whole value as gain, multi
  /// degraded to current-value-only) is gone — the cost-basis ledger gives both
  /// paths a real invested figure (market value on receipt) and a finite return.
  @Test("receive-only wallet: single and multi agree, both have an invested figure")
  func receiveOnlyWalletAgrees() async throws {
    let account = UUID()
    let receive = Transaction(date: day(-400), legs: [leg(account, eth, 1, .income)])
    let ledger = try await buildLedger([receive], rates: [eth.id: 500])
    let rows = [valued(eth, quantity: 1, worth: 500)]
    let single = try await AccountPerformanceCalculator.compute(
      accountId: account, valuedPositions: rows, profileCurrency: aud, ledger: ledger, now: day(0))
    let multi = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [account], valuedPositions: rows, profileCurrency: aud, ledger: ledger,
      now: day(0))
    expectAgreement(single, multi)
    #expect(multi.amountInvested == InstrumentAmount(quantity: 500, instrument: aud))
    #expect(multi.profitLoss == InstrumentAmount(quantity: 0, instrument: aud))
  }
}

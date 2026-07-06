import Foundation
import Testing

@testable import Moolah

@Suite("AccountPerformanceCalculator.computeMultiInstrument")
struct AccountPerformanceMultiInstrumentTests {
  private let aud = Instrument.AUD
  private let usd = Instrument.USD
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)

  private func day(_ n: Int) -> Date { Date(timeIntervalSinceReferenceDate: Double(n) * 86_400) }

  private func leg(
    _ account: UUID, _ i: Instrument, _ qty: Decimal, _ type: TransactionType
  ) -> TransactionLeg {
    TransactionLeg(accountId: account, instrument: i, quantity: qty, type: type)
  }

  private func valued(_ i: Instrument, quantity: Decimal, worth: InstrumentAmount) -> ValuedPosition
  {
    ValuedPosition(instrument: i, quantity: quantity, unitPrice: nil, costBasis: nil, value: worth)
  }

  private func buildLedger(
    _ txns: [Transaction], rates: [String: Decimal] = [:]
  ) async throws -> HoldingsCostLedger {
    try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates(rates))
  }

  /// A wallet that bought crypto has a real cost basis: invested + signed gain
  /// populate from the ledger.
  @Test("crypto buy populates amount invested and signed gain")
  func cryptoBuyPopulatesInvestedAndGain() async throws {
    let wallet = UUID()
    let buy = Transaction(
      date: day(0), legs: [leg(wallet, aud, -1_000, .trade), leg(wallet, eth, 1, .trade)])
    let ledger = try await buildLedger([buy])
    let perf = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [wallet],
      valuedPositions: [
        valued(eth, quantity: 1, worth: InstrumentAmount(quantity: 1_100, instrument: aud))
      ],
      profileCurrency: aud, ledger: ledger, now: day(365))
    #expect(perf.currentValue == InstrumentAmount(quantity: 1_100, instrument: aud))
    #expect(perf.totalContributions == InstrumentAmount(quantity: 1_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 100, instrument: aud))
  }

  /// The self-custody regression (spec's Return test): a wallet funded only by
  /// on-chain receives now yields a finite annualised return, because the
  /// received token is a positive inflow at market value. Under the old
  /// contributions path this had no external flow → nil return.
  @Test("self-custody wallet funded by receives has a finite return")
  func selfCustodyWalletReceivesOnlyHasFiniteReturn() async throws {
    let wallet = UUID()
    let receive = Transaction(date: day(-400), legs: [leg(wallet, eth, 1, .income)])
    let ledger = try await buildLedger([receive], rates: [eth.id: 4_000])
    let rows = [valued(eth, quantity: 1, worth: InstrumentAmount(quantity: 6_000, instrument: aud))]
    let perf = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [wallet], valuedPositions: rows, profileCurrency: aud, ledger: ledger, now: day(0)
    )
    #expect(perf.currentValue == InstrumentAmount(quantity: 6_000, instrument: aud))
    // Amount invested = market value on receipt (4,000), not a zero/negative flow.
    #expect(perf.totalContributions == InstrumentAmount(quantity: 4_000, instrument: aud))
    #expect(perf.annualisedReturn != nil)  // was nil under the old contributions path
  }

  /// A transfer between two members of the viewed set is internal: it nets to
  /// zero in the flows and carries cost between the members' lots, so the
  /// aggregate amount invested is unchanged and no phantom flow appears.
  @Test("internal transfer between members nets to zero and preserves invested")
  func internalTransferBetweenMembersNetsToZero() async throws {
    let memberA = UUID()
    let memberB = UUID()
    let buy = Transaction(
      date: day(0), legs: [leg(memberA, aud, -4_000, .trade), leg(memberA, eth, 2, .trade)])
    let move = Transaction(
      date: day(1),
      legs: [leg(memberA, eth, -1, .transfer), leg(memberB, eth, 1, .transfer)])
    let ledger = try await buildLedger([buy, move], rates: [eth.id: 2_500])
    let rows = [valued(eth, quantity: 2, worth: InstrumentAmount(quantity: 5_000, instrument: aud))]
    let perf = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [memberA, memberB], valuedPositions: rows,
      profileCurrency: aud, ledger: ledger, now: day(365))
    // Cost carries A→B; aggregate remaining invested stays 4,000 (2 ETH @ 2,000).
    #expect(perf.totalContributions == InstrumentAmount(quantity: 4_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 1_000, instrument: aud))  // 5000 − 4000
    // Only the buy is an external flow; the internal move adds none.
    #expect(perf.firstFlowDate == day(0))
  }

  /// A `ValuedPosition` whose `.value` is in a different instrument than
  /// `profileCurrency` must not trap. The aggregate is unavailable → currentValue
  /// and profitLoss are nil; amount invested (an empty ledger read) is 0.
  @Test("valued position in wrong instrument degrades to nil aggregate, no trap")
  func valuedPositionWrongInstrumentDegrades() async throws {
    let wallet = UUID()
    let ledger = try await buildLedger([])
    let rows = [
      valued(usd, quantity: 500, worth: InstrumentAmount(quantity: 750, instrument: usd))  // USD, not AUD
    ]
    let perf = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [wallet], valuedPositions: rows, profileCurrency: aud, ledger: ledger,
      now: day(30))
    #expect(perf.currentValue == nil)
    #expect(perf.profitLoss == nil)
    // No lots in the ledger → invested is a genuine 0, not a phantom.
    #expect(perf.totalContributions == InstrumentAmount(quantity: 0, instrument: aud))
  }

  /// A genuine flow conversion failure marks the instrument unavailable in the
  /// ledger (Rule 11): amount invested / gain are nil while the current value
  /// (already valued) survives.
  @Test("ledger conversion failure marks invested unavailable, value survives")
  func ledgerConversionFailureCurrentValueOnly() async throws {
    let wallet = UUID()
    let receive = Transaction(date: day(0), legs: [leg(wallet, eth, 1, .income)])
    let ledger = try await HoldingsCostLedger.build(
      transactions: [receive], referenceCurrency: aud,
      conversionService: FakeConversionService.failingInstruments([eth.id]))
    let rows = [valued(eth, quantity: 1, worth: InstrumentAmount(quantity: 1_100, instrument: aud))]
    let perf = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [wallet], valuedPositions: rows, profileCurrency: aud, ledger: ledger,
      now: day(365))
    #expect(perf.currentValue == InstrumentAmount(quantity: 1_100, instrument: aud))
    #expect(perf.totalContributions == nil)
    #expect(perf.profitLoss == nil)
  }

  /// Mixed success/failure across an in-scope instrument (Rule 11). Wallet A
  /// receives ETH twice: the earlier receipt's conversion fails and the later
  /// one succeeds, so A's `cashFlows` series is *truncated*. The return + first-
  /// flow date must NOT be computed from that partial series — the whole set
  /// degrades to current-value-only — while sibling wallet B, holding only a
  /// priced instrument, still gets a finite return.
  @Test("dropped in-scope flow hides return for the affected set; priced sibling unaffected")
  func mixedFailureHidesReturnForAffectedSet() async throws {
    let btc = Instrument.crypto(
      chainId: 2, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)
    let walletA = UUID()
    let walletB = UUID()
    let ethFail = Transaction(date: day(0), legs: [leg(walletA, eth, 1, .income)])
    let ethOk = Transaction(date: day(10), legs: [leg(walletA, eth, 1, .income)])
    let btcOk = Transaction(date: day(5), legs: [leg(walletB, btc, 1, .income)])
    let service = FakeConversionService.dateRates(
      [day(-100): [eth.id: 4_000, btc.id: 50_000]], failingDates: [day(0)])
    let ledger = try await HoldingsCostLedger.build(
      transactions: [ethFail, ethOk, btcOk], referenceCurrency: aud, conversionService: service)

    // Wallet A: the day(0) conversion failure poisons the whole set — the
    // partial flow series must not yield a return or first-flow date.
    let perfA = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [walletA],
      valuedPositions: [
        valued(eth, quantity: 2, worth: InstrumentAmount(quantity: 9_000, instrument: aud))
      ],
      profileCurrency: aud, ledger: ledger, now: day(365))
    #expect(perfA.currentValue == InstrumentAmount(quantity: 9_000, instrument: aud))
    #expect(perfA.totalContributions == nil)
    #expect(perfA.annualisedReturn == nil)
    #expect(perfA.firstFlowDate == nil)

    // Wallet B: only a priced instrument → a finite return survives.
    let perfB = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [walletB],
      valuedPositions: [
        valued(btc, quantity: 1, worth: InstrumentAmount(quantity: 60_000, instrument: aud))
      ],
      profileCurrency: aud, ledger: ledger, now: day(365))
    #expect(perfB.totalContributions == InstrumentAmount(quantity: 50_000, instrument: aud))
    #expect(perfB.annualisedReturn != nil)
    #expect(perfB.firstFlowDate == day(5))
  }
}

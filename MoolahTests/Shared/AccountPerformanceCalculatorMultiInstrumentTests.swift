import Foundation
import Testing

@testable import Moolah

// swiftlint:disable type_name
@Suite("AccountPerformanceCalculator.computeMultiInstrument")
struct AccountPerformanceCalculatorMultiInstrumentTests {
  // swiftlint:enable type_name
  let aud = Instrument.AUD
  let usd = Instrument.USD

  /// A cross-account deposit (external → wallet) establishes a contribution
  /// baseline, so contributions and P&L populate.
  @Test("cross-account funding populates contributions and signed P/L")
  func crossAccountFundingPopulatesPL() async throws {
    let wallet = UUID()
    let external = UUID()
    let openingDate = Date(timeIntervalSinceReferenceDate: 0)
    let now = openingDate.addingTimeInterval(365 * 86_400)
    // A transfer from `external` (an AUD source) into `wallet` as USD:
    // touches exactly one member of {wallet} → external flow of 1,000 AUD
    // (USD→AUD at 1.0 for the fake service).
    let funding = Transaction(
      date: openingDate,
      legs: [
        TransactionLeg(accountId: wallet, instrument: usd, quantity: 1_000, type: .transfer),
        TransactionLeg(accountId: external, instrument: aud, quantity: -1_000, type: .transfer),
      ])
    let valued = [
      ValuedPosition(
        instrument: usd, quantity: 1_000, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 1_100, instrument: aud))
    ]
    let perf = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [wallet],
      transactions: [funding],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]),
      now: now)
    #expect(perf.currentValue == InstrumentAmount(quantity: 1_100, instrument: aud))
    #expect(perf.totalContributions == InstrumentAmount(quantity: 1_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 100, instrument: aud))
  }

  /// A wallet funded only by single-account on-chain receives (no boundary
  /// crossing, no opening balance) has no known cost basis: current value
  /// shows, but contributions / P&L / return are nil — NOT "entire value is
  /// gain". Rule 11: no phantom gain.
  @Test("no-cost-basis wallet shows current value only, P/L nil")
  func noCostBasisWalletCurrentValueOnly() async throws {
    let wallet = UUID()
    let receiveDate = Date(timeIntervalSinceReferenceDate: 0)
    let receive = Transaction(
      date: receiveDate,
      legs: [
        // Single-account receive (airdrop): no other accountId, not an
        // opening balance → not a flow.
        TransactionLeg(accountId: wallet, instrument: usd, quantity: 500, type: .income)
      ])
    let valued = [
      ValuedPosition(
        instrument: usd, quantity: 500, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 750, instrument: aud))
    ]
    let perf = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [wallet],
      transactions: [receive],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]),
      now: receiveDate.addingTimeInterval(30 * 86_400))
    #expect(perf.currentValue == InstrumentAmount(quantity: 750, instrument: aud))
    #expect(perf.totalContributions == nil)
    #expect(perf.profitLoss == nil)
    #expect(perf.profitLossPercent == nil)
    #expect(perf.annualisedReturn == nil)
    #expect(perf.firstFlowDate == nil)
  }

  /// A transfer BETWEEN two group members touches ≥2 members → internal
  /// transfer → excluded from contributions (mirrors the chart baseline).
  @Test("internal transfer between group members is not a contribution")
  func internalGroupTransferExcluded() async throws {
    let memberA = UUID()
    let memberB = UUID()
    let openingDate = Date(timeIntervalSinceReferenceDate: 0)
    let now = openingDate.addingTimeInterval(365 * 86_400)
    let opening = Transaction(
      date: openingDate,
      legs: [
        TransactionLeg(accountId: memberA, instrument: aud, quantity: 1_000, type: .openingBalance)
      ])
    // A→B internal move: touches both members → excluded.
    let internalMove = Transaction(
      date: openingDate.addingTimeInterval(86_400),
      legs: [
        TransactionLeg(accountId: memberA, instrument: aud, quantity: -400, type: .transfer),
        TransactionLeg(accountId: memberB, instrument: aud, quantity: 400, type: .transfer),
      ])
    let valued = [
      ValuedPosition(
        instrument: aud, quantity: 1_100, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 1_100, instrument: aud))
    ]
    let perf = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [memberA, memberB],
      transactions: [opening, internalMove],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]),
      now: now)
    // Only the opening balance counts as a contribution; the internal move
    // does not. So contributions = 1,000 and P/L = 1,100 − 1,000 = 100.
    #expect(perf.totalContributions == InstrumentAmount(quantity: 1_000, instrument: aud))
    #expect(perf.profitLoss == InstrumentAmount(quantity: 100, instrument: aud))
  }

  /// A `ValuedPosition` whose `.value` is in a different instrument than
  /// `profileCurrency` must not trap (InstrumentAmount.+ has a precondition on
  /// matching instruments). The aggregate is unavailable → currentValueOnly(nil)
  /// → both currentValue and profitLoss are nil.
  @Test("valued position in wrong instrument degrades to nil aggregate, no trap")
  func valuedPositionWrongInstrumentDegrades() async throws {
    let wallet = UUID()
    // No transactions → no flows, so the only path to perf is through
    // aggregatedValue. The position's value is USD but profileCurrency is AUD:
    // before the guard fix this would have trapped on InstrumentAmount.+=.
    let valued = [
      ValuedPosition(
        instrument: usd, quantity: 500, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 750, instrument: usd))  // USD, not AUD
    ]
    let perf = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [wallet],
      transactions: [],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]),
      now: Date(timeIntervalSinceReferenceDate: 30 * 86_400))
    // Instrument mismatch → aggregate unavailable → currentValueOnly(nil, in: aud)
    #expect(perf.currentValue == nil)
    #expect(perf.totalContributions == nil)
    #expect(perf.profitLoss == nil)
  }

  /// A flow-conversion failure degrades to current value only (which is known
  /// from the already-valued rows) rather than throwing or partial-summing.
  @Test("flow conversion failure degrades to current value only")
  func flowConversionFailureCurrentValueOnly() async throws {
    let wallet = UUID()
    let external = UUID()
    let openingDate = Date(timeIntervalSinceReferenceDate: 0)
    let funding = Transaction(
      date: openingDate,
      legs: [
        TransactionLeg(accountId: wallet, instrument: usd, quantity: 1_000, type: .transfer),
        TransactionLeg(accountId: external, instrument: aud, quantity: -1_000, type: .transfer),
      ])
    let valued = [
      ValuedPosition(
        instrument: usd, quantity: 1_000, unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 1_100, instrument: aud))
    ]
    // USD flow conversion fails → contributions unavailable.
    let failing = FakeConversionService.failingInstruments([usd.id])
    let perf = try await AccountPerformanceCalculator.computeMultiInstrument(
      accountIds: [wallet],
      transactions: [funding],
      valuedPositions: valued,
      profileCurrency: aud,
      conversionService: failing,
      now: openingDate.addingTimeInterval(365 * 86_400))
    #expect(perf.currentValue == InstrumentAmount(quantity: 1_100, instrument: aud))
    #expect(perf.totalContributions == nil)
    #expect(perf.profitLoss == nil)
  }
}

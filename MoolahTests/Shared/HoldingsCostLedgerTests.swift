import Foundation
import Testing

@testable import Moolah

/// Integration tests for `HoldingsCostLedger`: fiat suppression, the
/// negative-invested crypto shape (self-custody receive-then-send),
/// acquisition-before-disposal ordering, `.knownZero`/Rule 11 isolation,
/// same-day last-wins change-points, per-date valuation, and zone-invariant
/// lookups. Uses the `build(transactions:)` convenience so the tests stay
/// transaction-shaped.
@Suite("HoldingsCostLedger")
struct HoldingsCostLedgerTests {
  private let aud = Instrument.AUD
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  private let btc = Instrument.crypto(
    chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)

  private func day(_ n: Int) -> Date {
    Date(timeIntervalSince1970: 1_700_000_000 + Double(n) * 86_400)
  }

  private func leg(
    _ account: UUID?, _ instrument: Instrument, _ quantity: Decimal, _ type: TransactionType
  ) -> TransactionLeg {
    TransactionLeg(accountId: account, instrument: instrument, quantity: quantity, type: type)
  }

  // MARK: - Fiat suppression + non-negative invariant

  @Test
  func fiatOnlyAccount_hasZeroInvested_noBaseline() async throws {
    let accountA = UUID()
    let txns = [
      Transaction(date: day(0), legs: [leg(accountA, aud, 10_000, .openingBalance)]),
      Transaction(date: day(5), legs: [leg(accountA, aud, 500, .income)]),
    ]
    let ledger = try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:]))
    #expect(ledger.remainingInvested(accountIds: [accountA], onOrBefore: day(30)) == 0)
  }

  @Test
  func selfCustodyReceivesThenSendsOut_investedNeverNegative() async throws {
    // Trust-Ethereum replay shape: external on-chain receives (.income) then
    // one boundary-crossing outflow (.expense). Old contributions went negative.
    let accountA = UUID()
    let txns = [
      Transaction(date: day(0), legs: [leg(accountA, eth, 2, .income)]),
      Transaction(date: day(10), legs: [leg(accountA, eth, 3, .income)]),
      Transaction(date: day(20), legs: [leg(accountA, eth, -4, .expense)]),
    ]
    let ledger = try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 5_000]))
    for n in 0...30 {
      let invested = try #require(
        ledger.remainingInvested(accountIds: [accountA], onOrBefore: day(n)))
      #expect(invested >= 0)
    }
    // After sending 4 of 5 ETH, 1 ETH remains @ its acquisition value (5000).
    #expect(ledger.remainingInvested(accountIds: [accountA], onOrBefore: day(30)) == 5_000)
  }

  // MARK: - Ordering: acquisitions before disposals

  @Test
  func gasFeePaidInSameTxnAsPurchase_disposesFromJustAcquiredLot() async throws {
    // Buy 1 ETH and pay a 0.01 ETH gas fee in the SAME transaction, no prior
    // ETH holding. Acquisitions-first lets the gas disposal draw the just-
    // acquired lot rather than being dropped against an empty bucket.
    let accountA = UUID()
    let txns = [
      Transaction(
        date: day(0),
        legs: [
          leg(accountA, aud, -2_000, .trade),
          leg(accountA, eth, 1, .trade),
          leg(accountA, eth, dec("-0.01"), .expense),
        ])
    ]
    let ledger = try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 2_000]))
    // The gas disposal was applied (not dropped): 0.99 ETH remains — with
    // OLD disposals-first ordering the gas leg would hit an empty bucket,
    // be dropped, and leave a full 1.0 ETH. The classifier folds the 0.01
    // ETH gas into the buy cost (costPerUnit 2020), so remaining invested is
    // 0.99 × 2020 = 1999.8 (not the dropped-gas 1.0 × 2020 = 2020).
    let remainingQty =
      ledger.openLots
      .filter { $0.instrument == eth }
      .reduce(Decimal(0)) { $0 + $1.remainingQuantity }
    #expect(remainingQty == dec("0.99"))
    #expect(ledger.remainingInvested(accountIds: [accountA], onOrBefore: day(0)) == dec("1999.8"))
    #expect(ledger.realisedEvents.count == 1)
  }

  // MARK: - Transfer nuance + realised disposals

  @Test
  func transferBetweenTrackedAccounts_noRealisedGain_investedMoves() async throws {
    let accountA = UUID()
    let accountB = UUID()
    let txns = [
      Transaction(date: day(0), legs: [leg(accountA, eth, 1, .income)]),
      Transaction(
        date: day(5), legs: [leg(accountA, eth, -1, .transfer), leg(accountB, eth, 1, .transfer)]),
    ]
    let ledger = try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 4_000]))
    #expect(ledger.realisedEvents.isEmpty)  // move is not a CGT event
    #expect(ledger.remainingInvested(accountIds: [accountA], onOrBefore: day(10)) == 0)  // drained
    // Destination holds the original invested cost, not the day-5 market value.
    #expect(ledger.remainingInvested(accountIds: [accountB], onOrBefore: day(10)) == 4_000)
    // Aggregate over {a,b}: the move nets out of cashFlows, leaving only income.
    #expect(ledger.cashFlows(accountIds: [accountA, accountB]).count == 1)
  }

  @Test
  func externalExpenseSend_realisesGain() async throws {
    let accountA = UUID()
    let txns = [
      Transaction(date: day(0), legs: [leg(accountA, eth, 1, .income)]),  // acquired @ 2000
      Transaction(date: day(400), legs: [leg(accountA, eth, -1, .expense)]),  // spent @ 2000 (flat)
    ]
    let ledger = try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 2_000]))
    #expect(ledger.realisedEvents.count == 1)
    #expect(ledger.realisedEvents[0].instrument == eth)
    #expect(ledger.remainingInvested(accountIds: [accountA], onOrBefore: day(400)) == 0)
  }

  // MARK: - .knownZero + Rule 11 isolation

  @Test
  func spamAirdropIncome_valuedZero_buildSucceeds() async throws {
    // An unpriced / spam token arrives as `.income`; `convertResult` returns
    // `.knownZero` → acquisition valued 0. The build must NOT abort and the
    // account's invested is a real 0 (available), not `nil`.
    let accountA = UUID()
    let txns = [Transaction(date: day(0), legs: [leg(accountA, eth, 5, .income)])]
    let ledger = try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([:], knownZero: [eth.id]))
    let invested = ledger.remainingInvested(accountIds: [accountA], onOrBefore: day(30))
    #expect(invested != nil)
    #expect(invested == 0)
  }

  @Test
  func genuineConversionFailure_isolatesOnlyTheAffectedKey() async throws {
    // ETH conversion fails outright; BTC is priced. The ETH-holding account
    // returns `nil` (Rule 11, no partial sum); the sibling BTC-only account
    // still returns a real value.
    let accountA = UUID()  // holds ETH (fails)
    let accountB = UUID()  // holds BTC (priced)
    let txns = [
      Transaction(date: day(0), legs: [leg(accountA, eth, 1, .income)]),
      Transaction(date: day(1), legs: [leg(accountB, btc, 1, .income)]),
    ]
    let ledger = try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: aud,
      conversionService: FakeConversionService.failingInstruments(
        [eth.id], rates: [btc.id: 1_000]))
    #expect(ledger.remainingInvested(accountIds: [accountA], onOrBefore: day(10)) == nil)
    #expect(ledger.remainingInvested(accountIds: [accountB], onOrBefore: day(10)) == 1_000)
  }

  // MARK: - Same-day change-point: last-wins

  @Test
  func twoSameDayTransactions_lastCumulativeInvestedWins() async throws {
    // Two ETH acquisitions on the same day for one account: the change-point
    // for that (account, instrument, day) must reflect the cumulative invested
    // after BOTH (the last snapshot), not the first.
    let accountA = UUID()
    let txns = [
      Transaction(date: day(5), legs: [leg(accountA, eth, 1, .income)]),
      Transaction(date: day(5), legs: [leg(accountA, eth, 1, .income)]),
    ]
    let ledger = try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 3_000]))
    #expect(ledger.remainingInvested(accountIds: [accountA], onOrBefore: day(5)) == 6_000)
  }

  // MARK: - Per-date valuation

  @Test
  func acquisitionsValuedAtTransactionDateRate() async throws {
    // Each lot is valued at ITS OWN transaction-date rate (not a fixed rate
    // and not `Date()`), so the cumulative invested reflects both days.
    let accountA = UUID()
    let rates: [Date: [String: Decimal]] = [
      day(0): [eth.id: 1_000],
      day(10): [eth.id: 3_000],
    ]
    let txns = [
      Transaction(date: day(0), legs: [leg(accountA, eth, 1, .income)]),
      Transaction(date: day(10), legs: [leg(accountA, eth, 1, .income)]),
    ]
    let ledger = try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: aud,
      conversionService: FakeConversionService.dateRates(rates))
    #expect(ledger.remainingInvested(accountIds: [accountA], onOrBefore: day(0)) == 1_000)
    #expect(ledger.remainingInvested(accountIds: [accountA], onOrBefore: day(10)) == 4_000)
  }

  // MARK: - Zone invariance

  /// A spread of zones either side of UTC — mirrors `TimezonelessDateTests`.
  private static let zones = [
    "America/Los_Angeles",  // UTC-8 / -7
    "UTC",
    "Australia/Brisbane",  // UTC+10, no DST
    "Pacific/Kiritimati",  // UTC+14, the extreme positive case
  ]

  @Test("remainingInvested change-point lookup is zone-invariant")
  func remainingInvestedIsZoneInvariant() async throws {
    let accountA = UUID()
    let ledger = try await HoldingsCostLedger.build(
      transactions: [Transaction(date: day(0), legs: [leg(accountA, eth, 1, .income)])],
      referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 3_000]))

    let originalZone = NSTimeZone.default
    defer { NSTimeZone.default = originalZone }

    var resultsPerZone: [String: Decimal?] = [:]
    for identifier in Self.zones {
      NSTimeZone.default = try #require(TimeZone(identifier: identifier))
      // The change-point lookup compares `startOfDay` via `Calendar.utc`,
      // never `TimeZone.current`, so the at-or-before boundary must not
      // drift with the host zone.
      resultsPerZone[identifier] = ledger.remainingInvested(
        accountIds: [accountA], onOrBefore: day(0))
    }
    #expect(resultsPerZone["UTC"] == 3_000)
    for identifier in Self.zones {
      #expect(resultsPerZone[identifier] == 3_000, "invested drifted in \(identifier)")
    }
  }
}

import Foundation
import Testing

@testable import Moolah

/// Integration tests for `HoldingsCostLedger`: fiat suppression, the
/// negative-invested crypto shape (self-custody receive-then-send), tracked
/// transfer nuance, expense disposals realising gains, and zone-invariant
/// change-point lookups. Uses the `build(transactions:)` convenience so the
/// tests stay transaction-shaped.
@Suite("HoldingsCostLedger")
struct HoldingsCostLedgerTests {
  private let aud = Instrument.AUD
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)

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
      #expect(ledger.remainingInvested(accountIds: [accountA], onOrBefore: day(n)) >= 0)
    }
    // After sending 4 of 5 ETH, 1 ETH remains @ its acquisition value (5000).
    #expect(ledger.remainingInvested(accountIds: [accountA], onOrBefore: day(30)) == 5_000)
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
    #expect(ledger.remainingInvested(accountIds: [accountA], onOrBefore: day(10)) == 0)  // source drained
    // Destination holds the original invested cost, not the day-5 market value.
    #expect(ledger.remainingInvested(accountIds: [accountB], onOrBefore: day(10)) == 4_000)
    // Aggregate over {accountA,accountB}: the move nets out of cashFlows, leaving only income.
    #expect(ledger.cashFlows(accountIds: [accountA, accountB]).count == 1)
  }

  @Test
  func externalExpenseSend_realisesGain() async throws {
    let accountA = UUID()
    let txns = [
      Transaction(date: day(0), legs: [leg(accountA, eth, 1, .income)]),  // acquired @ 2000
      Transaction(date: day(400), legs: [leg(accountA, eth, -1, .expense)]),  // spent @ 2000 (flat fake)
    ]
    let ledger = try await HoldingsCostLedger.build(
      transactions: txns, referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([eth.id: 2_000]))
    #expect(ledger.realisedEvents.count == 1)
    #expect(ledger.realisedEvents[0].instrument == eth)
    #expect(ledger.remainingInvested(accountIds: [accountA], onOrBefore: day(400)) == 0)
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

    var resultsPerZone: [String: Decimal] = [:]
    for identifier in Self.zones {
      NSTimeZone.default = try #require(TimeZone(identifier: identifier))
      // The change-point lookup compares `startOfDay` via `Calendar.utc`,
      // never `TimeZone.current`, so the at-or-before boundary must not
      // drift with the host zone.
      resultsPerZone[identifier] = ledger.remainingInvested(
        accountIds: [accountA], onOrBefore: day(0))
    }
    let reference = try #require(resultsPerZone["UTC"])
    #expect(reference == 3_000)
    for identifier in Self.zones {
      #expect(resultsPerZone[identifier] == reference, "invested drifted in \(identifier)")
    }
  }
}

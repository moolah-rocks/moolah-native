import Foundation
import Testing

@testable import Moolah

@Suite("CapitalGainsCalculator owner partitioning")
struct CapitalGainsCalculatorOwnerTests {
  private let aud = Instrument.AUD
  private let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  private let spam = Instrument.crypto(
    chainId: 10,
    contractAddress: "0x21841eb46ccce03ebe57b4ee6eb547f31dfde152",
    symbol: "SPAM",
    name: "Spam Token",
    decimals: 18)
  private let defaultOwner = makeUUID("00000000-0000-0000-0000-000000000001")
  private let ownerA = makeUUID("00000000-0000-0000-0000-00000000000A")
  private let ownerB = makeUUID("00000000-0000-0000-0000-00000000000B")
  private let accountA = makeUUID("10000000-0000-0000-0000-00000000000A")
  private let accountB = makeUUID("10000000-0000-0000-0000-00000000000B")
  private let accountC = makeUUID("10000000-0000-0000-0000-00000000000C")
  private let jointAccount = makeUUID("20000000-0000-0000-0000-000000000000")

  @Test
  func differentOwnersDoNotShareLotsWhileSameOwnerAccountsDo() async throws {
    let ledger = try await buildLedger(
      transactions: [
        buy(on: 0, account: accountA, shares: 100, cash: 4_000),
        sell(on: 100, account: accountB, shares: 100, proceeds: 5_000),
        sell(on: 200, account: accountC, shares: 100, proceeds: 6_000),
      ],
      accounts: [
        account(id: accountA, owners: [ownerA]),
        account(id: accountB, owners: [ownerB]),
        account(id: accountC, owners: [ownerA]),
      ])

    let ownerBResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerB)
    let ownerAResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerA)
    let allOwnersResult = CapitalGainsCalculator.compute(ledger: ledger)

    #expect(
      ownerBResult.events.isEmpty,
      "owner B's sale must not consume owner A's FIFO lot")
    #expect(ownerAResult.events.count == 1)
    guard let ownerAEvent = ownerAResult.events.first else {
      Issue.record("expected owner A's later sale to consume owner A's lot")
      return
    }
    #expect(ownerAEvent.quantity == 100)
    #expect(ownerAEvent.gain == 2_000)
    #expect(allOwnersResult.totalRealizedGain == ownerAResult.totalRealizedGain)
  }

  @Test
  func ownerFilteredResultIgnoresOtherOwnersUnavailableCostBasis() async throws {
    let ledger = try await buildLedger(
      transactions: [
        Transaction(
          date: day(0),
          legs: [
            leg(account: accountA, instrument: spam, quantity: -10),
            leg(account: accountA, instrument: bhp, quantity: 1),
          ]),
        buy(on: 100, account: accountB, shares: 100, cash: 4_000),
        sell(on: 500, account: accountB, shares: 100, proceeds: 5_000),
      ],
      accounts: [
        account(id: accountA, owners: [ownerA]),
        account(id: accountB, owners: [ownerB]),
      ],
      conversionService: FakeConversionService.failingInstruments([spam.id]))

    let ownerAResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerA)
    let ownerBResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerB)

    #expect(ownerAResult.hasUnavailableData)
    #expect(ownerAResult.unavailableInstruments == [spam, bhp])
    #expect(ownerBResult.hasUnavailableData == false)
    #expect(ownerBResult.unavailableInstruments.isEmpty)
    #expect(ownerBResult.totalRealizedGain == 1_000)
  }

  @Test
  func crossOwnerCustomTradeDisposesSourceAndAcquiresDestination() async throws {
    let ledger = try await buildLedger(
      transactions: [
        buy(on: 0, account: accountA, shares: 100, cash: 4_000),
        Transaction(
          id: makeUUID("60000000-0000-0000-0000-000100000000"),
          date: day(100),
          legs: [
            leg(account: accountA, instrument: bhp, quantity: -100),
            leg(account: accountB, instrument: spam, quantity: 10),
          ]),
      ],
      accounts: [
        account(id: accountA, owners: [ownerA]),
        account(id: accountB, owners: [ownerB]),
      ],
      conversionService: FakeConversionService.fixedRates([
        bhp.id: 50,
        spam.id: 500,
      ]))

    let ownerAResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerA)
    let ownerBResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerB)
    let allOwnersResult = CapitalGainsCalculator.compute(ledger: ledger)

    #expect(
      ownerAResult.events.count == 1,
      "source owner must realise the disposed side of a cross-owner custom trade")
    let ownerADisposal = try #require(ownerAResult.events.first)
    #expect(ownerADisposal.sellDate == day(100))
    #expect(ownerADisposal.acquiredDate == day(0))
    #expect(ownerADisposal.quantity == 100)
    #expect(ownerADisposal.costBasis == 4_000)
    #expect(ownerADisposal.proceeds == 5_000)
    #expect(ownerADisposal.gain == 1_000)
    #expect(ownerADisposal.taxOwnerId == ownerA)

    #expect(
      ownerBResult.events.isEmpty,
      "destination owner acquisition must not realise the source owner's gain")
    let ownerBLot = try #require(ownerBResult.openLots.first)
    #expect(ownerBResult.openLots.count == 1)
    #expect(ownerBLot.account == accountB)
    #expect(ownerBLot.acquiredDate == day(100))
    #expect(ownerBLot.remainingQuantity == 10)
    #expect(ownerBLot.costPerUnit == 500)
    #expect(ownerBLot.taxOwnerId == ownerB)
    #expect(allOwnersResult.events == ownerAResult.events)
  }

  @Test
  func jointOwnerAccountSplitsQuantityAndGainEvenly() async throws {
    let ledger = try await buildLedger(
      transactions: [
        buy(on: 0, account: jointAccount, shares: 100, cash: 4_000),
        sell(on: 400, account: jointAccount, shares: 100, proceeds: 6_000),
      ],
      accounts: [account(id: jointAccount, owners: [ownerA, ownerB])])

    let ownerAResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerA)
    let ownerBResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerB)
    let allOwnersResult = CapitalGainsCalculator.compute(ledger: ledger)

    guard let ownerAEvent = ownerAResult.events.first,
      let ownerBEvent = ownerBResult.events.first
    else {
      Issue.record("expected each joint owner to receive one split gain event")
      return
    }
    #expect(ownerAResult.events.count == 1)
    #expect(ownerBResult.events.count == 1)
    #expect(ownerAEvent.quantity == 50)
    #expect(ownerBEvent.quantity == 50)
    #expect(ownerAEvent.gain == 1_000)
    #expect(ownerBEvent.gain == 1_000)
    #expect(
      allOwnersResult.totalRealizedGain
        == ownerAResult.totalRealizedGain + ownerBResult.totalRealizedGain,
      "all-owner CGT must be the sum of owner-partitioned outputs")
  }

  @Test
  func changedAccountOwnerReattributesHistoricalTradesWithoutExtraDisposal() async throws {
    let transactions = [
      buy(on: 0, account: accountA, shares: 100, cash: 4_000),
      sell(on: 400, account: accountA, shares: 100, proceeds: 6_000),
    ]
    let ledger = try await buildLedger(
      transactions: transactions,
      accounts: [account(id: accountA, owners: [ownerB])])

    let previousOwnerResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerA)
    let currentOwnerResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerB)
    let allOwnersResult = CapitalGainsCalculator.compute(ledger: ledger)

    #expect(previousOwnerResult.events.isEmpty)
    #expect(currentOwnerResult.events.count == 1)
    guard let currentOwnerEvent = currentOwnerResult.events.first else {
      Issue.record("expected the current owner to receive the historical gain")
      return
    }
    #expect(currentOwnerEvent.quantity == 100)
    #expect(currentOwnerEvent.gain == 2_000)
    #expect(
      allOwnersResult.events.count == 1,
      "changing current tax owner assignment must not create a deemed disposal")
  }

  private func buildLedger(
    transactions: [Transaction],
    accounts: [Account],
    conversionService: any InstrumentConversionService = FakeConversionService.fixedRates([:])
  ) async throws -> HoldingsCostLedger {
    let resolver = TaxOwnershipResolver(
      profileDefaultOwnerId: defaultOwner,
      accounts: accounts,
      categories: [])
    return try await HoldingsCostLedger.build(
      transactions: transactions,
      referenceCurrency: aud,
      conversionService: conversionService,
      taxOwnershipResolver: resolver)
  }

  private func account(id: UUID, owners: [UUID]) -> Account {
    Account(
      id: id,
      name: "CGT account \(id.uuidString)",
      type: .investment,
      instrument: aud,
      taxOwnerIds: owners)
  }

  private func buy(
    on dayNumber: Int,
    account: UUID,
    shares: Decimal,
    cash: Decimal
  ) -> Transaction {
    Transaction(
      id: makeUUID("30000000-0000-0000-0000-\(padded(dayNumber))000000"),
      date: day(dayNumber),
      legs: [
        leg(account: account, instrument: aud, quantity: -cash),
        leg(account: account, instrument: bhp, quantity: shares),
      ])
  }

  private func sell(
    on dayNumber: Int,
    account: UUID,
    shares: Decimal,
    proceeds: Decimal
  ) -> Transaction {
    Transaction(
      id: makeUUID("40000000-0000-0000-0000-\(padded(dayNumber))000000"),
      date: day(dayNumber),
      legs: [
        leg(account: account, instrument: bhp, quantity: -shares),
        leg(account: account, instrument: aud, quantity: proceeds),
      ])
  }

  private func leg(
    account: UUID,
    instrument: Instrument,
    quantity: Decimal,
    type: TransactionType = .trade
  ) -> TransactionLeg {
    TransactionLeg(
      accountId: account,
      instrument: instrument,
      quantity: quantity,
      type: type)
  }

  private func day(_ n: Int) -> Date {
    let calendar = AustralianTaxCalendar.calendar
    guard
      let base = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)),
      let result = calendar.date(byAdding: .day, value: n, to: base)
    else {
      fatalError("Could not construct date \(n) days from 2024-01-01")
    }
    return result
  }

  private func padded(_ value: Int) -> String {
    String(format: "%06d", value)
  }
}

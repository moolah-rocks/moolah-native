import Foundation
import Testing

@testable import Moolah

@Suite("CapitalGainsCalculator transfer owner changes")
struct CapitalGainsCalculatorTransferOwnerTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let defaultOwner = makeUUID("00000000-0000-0000-0000-000000000001")
  let ownerA = makeUUID("00000000-0000-0000-0000-00000000000A")
  let ownerB = makeUUID("00000000-0000-0000-0000-00000000000B")
  let ownerC = makeUUID("00000000-0000-0000-0000-00000000000C")
  let accountA = makeUUID("10000000-0000-0000-0000-00000000000A")
  let accountB = makeUUID("10000000-0000-0000-0000-00000000000B")
  let accountC = makeUUID("10000000-0000-0000-0000-00000000000C")
  let jointAccount = makeUUID("20000000-0000-0000-0000-000000000000")

  @Test
  func sameOwnerNonFiatTransferIsNonTaxableAndLaterSaleKeepsOriginalCostBasis() async throws {
    let ledger = try await buildLedger(
      transactions: [
        buy(on: 0, account: accountA, shares: 100, cash: 4_000),
        transfer(on: 100, from: accountA, to: accountC, instrument: bhp, quantity: 100),
        sell(on: 200, account: accountC, shares: 100, proceeds: 6_000),
      ],
      accounts: [
        account(id: accountA, owners: [ownerA]),
        account(id: accountC, owners: [ownerA]),
      ],
      conversionService: FakeConversionService.fixedRates([bhp.id: 50]))

    let ownerAResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerA)
    let allOwnersResult = CapitalGainsCalculator.compute(ledger: ledger)

    #expect(
      ownerAResult.events.count == 1,
      "same-owner transfer must not create its own CGT event")
    let saleEvent = try #require(ownerAResult.events.first)
    #expect(saleEvent.sellDate == day(200))
    #expect(saleEvent.acquiredDate == day(0))
    #expect(saleEvent.quantity == 100)
    #expect(saleEvent.costBasis == 4_000)
    #expect(saleEvent.proceeds == 6_000)
    #expect(saleEvent.gain == 2_000)
    #expect(allOwnersResult.events == ownerAResult.events)
  }

  @Test
  func sameOwnerNonFiatTransferMovesOpenLotWithoutMarketValue() async throws {
    let ledger = try await buildLedger(
      transactions: [
        buy(on: 0, account: accountA, shares: 100, cash: 4_000),
        transfer(on: 100, from: accountA, to: accountC, instrument: bhp, quantity: 100),
      ],
      accounts: [
        account(id: accountA, owners: [ownerA]),
        account(id: accountC, owners: [ownerA]),
      ],
      conversionService: FakeConversionService.failingInstruments([bhp.id]))

    let ownerAResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerA)

    #expect(ownerAResult.events.isEmpty)
    #expect(ownerAResult.hasUnavailableData == false)
    let movedLot = try #require(ownerAResult.openLots.first)
    #expect(ownerAResult.openLots.count == 1)
    #expect(movedLot.account == accountC)
    #expect(movedLot.acquiredDate == day(0))
    #expect(movedLot.remainingQuantity == 100)
    #expect(movedLot.costPerUnit == 40)
    #expect(movedLot.taxOwnerId == ownerA)
  }

  @Test
  func differentOwnerNonFiatTransferDisposesForSourceAndAcquiresForDestinationAtMarketValue()
    async throws
  {
    let ledger = try await buildLedger(
      transactions: [
        buy(on: 0, account: accountA, shares: 100, cash: 4_000),
        transfer(on: 100, from: accountA, to: accountB, instrument: bhp, quantity: 100),
      ],
      accounts: [
        account(id: accountA, owners: [ownerA]),
        account(id: accountB, owners: [ownerB]),
      ],
      conversionService: FakeConversionService.fixedRates([bhp.id: 50]))

    let ownerAResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerA)
    let ownerBResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerB)

    #expect(
      ownerAResult.events.count == 1,
      "source owner must realise a disposal when ownership changes")
    let ownerADisposal = try #require(ownerAResult.events.first)
    #expect(ownerADisposal.sellDate == day(100))
    #expect(ownerADisposal.acquiredDate == day(0))
    #expect(ownerADisposal.quantity == 100)
    #expect(ownerADisposal.costBasis == 4_000)
    #expect(ownerADisposal.proceeds == 5_000)
    #expect(ownerADisposal.gain == 1_000)
    #expect(ownerADisposal.taxOwnerId == ownerA)

    #expect(
      ownerBResult.openLots.count == 1,
      "destination owner must receive a new acquisition lot at transfer market value")
    let ownerBLot = try #require(ownerBResult.openLots.first)
    #expect(ownerBLot.acquiredDate == day(100))
    #expect(ownerBLot.remainingQuantity == 100)
    #expect(ownerBLot.costPerUnit == 50)
    #expect(ownerBLot.taxOwnerId == ownerB)
    #expect(ownerBResult.events.isEmpty)
  }

  @Test
  func ownerChangingNonFiatTransferWithUnavailableMarketValueMarksSourceIntervalUnavailable()
    async throws
  {
    let ledger = try await buildLedger(
      transactions: [
        buy(on: 0, account: accountA, shares: 100, cash: 4_000),
        transfer(on: 100, from: accountA, to: accountB, instrument: bhp, quantity: 100),
      ],
      accounts: [
        account(id: accountA, owners: [ownerA]),
        account(id: accountB, owners: [ownerB]),
      ],
      conversionService: FakeConversionService.failingInstruments([bhp.id]))

    let ownerAIntervalResult = CapitalGainsCalculator.compute(
      ledger: ledger,
      sellDateInterval: day(50)..<day(150),
      ownerId: ownerA)

    #expect(ownerAIntervalResult.events.isEmpty)
    #expect(ownerAIntervalResult.totalRealizedGain == 0)
    #expect(
      ownerAIntervalResult.hasUnavailableData,
      "failed transfer market-value conversion must make the date-filtered CGT result unavailable, not complete zero"
    )
    #expect(ownerAIntervalResult.unavailableInstruments == [bhp])
    #expect(ownerAIntervalResult.unavailableInstrumentIds == [bhp.id])

  }

  @Test
  func partialOwnerOverlapTransferOnlyTaxedForChangingOwnersAndPreservesOverlappingOwnersCost()
    async throws
  {
    let ledger = try await buildLedger(
      transactions: [
        buy(on: 0, account: jointAccount, shares: 100, cash: 4_000),
        transfer(on: 100, from: jointAccount, to: accountC, instrument: bhp, quantity: 100),
        sell(on: 200, account: accountC, shares: 100, proceeds: 6_000),
      ],
      accounts: [
        account(id: jointAccount, owners: [ownerA, ownerB]),
        account(id: accountC, owners: [ownerB, ownerC]),
      ],
      conversionService: FakeConversionService.fixedRates([bhp.id: 50]))

    let ownerAResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerA)
    let ownerBResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerB)
    let ownerCResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerC)

    #expect(
      ownerAResult.events.count == 1,
      "only owner A's changing half should be disposed at transfer")
    let ownerADisposal = try #require(ownerAResult.events.first)
    #expect(ownerADisposal.sellDate == day(100))
    #expect(ownerADisposal.quantity == 50)
    #expect(ownerADisposal.costBasis == 2_000)
    #expect(ownerADisposal.proceeds == 2_500)
    #expect(ownerADisposal.gain == 500)
    #expect(ownerADisposal.taxOwnerId == ownerA)

    #expect(
      ownerBResult.events.count == 1,
      "overlapping owner B should only realise the later sale, not the transfer")
    let ownerBSale = try #require(ownerBResult.events.first)
    #expect(ownerBSale.sellDate == day(200))
    #expect(ownerBSale.acquiredDate == day(0))
    #expect(ownerBSale.quantity == 50)
    #expect(ownerBSale.costBasis == 2_000)
    #expect(ownerBSale.proceeds == 3_000)
    #expect(ownerBSale.gain == 1_000)
    #expect(ownerBSale.taxOwnerId == ownerB)

    #expect(
      ownerCResult.events.count == 1,
      "new owner C should acquire only the changing half at transfer market value")
    let ownerCSale = try #require(ownerCResult.events.first)
    #expect(ownerCSale.sellDate == day(200))
    #expect(ownerCSale.acquiredDate == day(100))
    #expect(ownerCSale.quantity == 50)
    #expect(ownerCSale.costBasis == 2_500)
    #expect(ownerCSale.proceeds == 3_000)
    #expect(ownerCSale.gain == 500)
    #expect(ownerCSale.taxOwnerId == ownerC)
  }
  @Test
  func fiatOnlyTransfersRemainNonTaxableForEveryOwner() async throws {
    let ledger = try await buildLedger(
      transactions: [
        transfer(on: 100, from: accountA, to: accountB, instrument: aud, quantity: 5_000)
      ],
      accounts: [
        account(id: accountA, owners: [ownerA]),
        account(id: accountB, owners: [ownerB]),
      ])

    let ownerAResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerA)
    let ownerBResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerB)
    let allOwnersResult = CapitalGainsCalculator.compute(ledger: ledger)

    #expect(ownerAResult.events.isEmpty)
    #expect(ownerBResult.events.isEmpty)
    #expect(allOwnersResult.events.isEmpty)
  }

}

extension CapitalGainsCalculatorTransferOwnerTests {
  func buildLedger(
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

  func account(id: UUID, owners: [UUID]) -> Account {
    Account(
      id: id,
      name: "CGT transfer account \(id.uuidString)",
      type: .investment,
      instrument: aud,
      taxOwnerIds: owners)
  }

  func buy(
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

  func sell(
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

  func transfer(
    on dayNumber: Int,
    from sourceAccount: UUID,
    to destinationAccount: UUID,
    instrument: Instrument,
    quantity: Decimal
  ) -> Transaction {
    Transaction(
      id: makeUUID("50000000-0000-0000-0000-\(padded(dayNumber))000000"),
      date: day(dayNumber),
      legs: [
        leg(account: sourceAccount, instrument: instrument, quantity: -quantity, type: .transfer),
        leg(
          account: destinationAccount, instrument: instrument, quantity: quantity,
          type: .transfer),
      ])
  }

  func leg(
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

  func day(_ n: Int) -> Date {
    let calendar = AustralianTaxCalendar.calendar
    guard
      let base = calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)),
      let result = calendar.date(byAdding: .day, value: n, to: base)
    else {
      fatalError("Could not construct date \(n) days from 2024-01-01")
    }
    return result
  }

  func padded(_ value: Int) -> String {
    String(format: "%06d", value)
  }
}

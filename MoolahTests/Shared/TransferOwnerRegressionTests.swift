import Foundation
import Testing

@testable import Moolah

@Suite("CapitalGainsCalculator transfer owner regressions")
struct TransferOwnerRegressionTests {
  private let aud = Instrument.AUD
  private let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  private let defaultOwner = makeUUID("00000000-0000-0000-0000-000000000001")
  private let ownerA = makeUUID("00000000-0000-0000-0000-00000000000A")
  private let ownerB = makeUUID("00000000-0000-0000-0000-00000000000B")
  private let ownerC = makeUUID("00000000-0000-0000-0000-00000000000C")
  private let accountA = makeUUID("10000000-0000-0000-0000-00000000000A")
  private let accountB = makeUUID("10000000-0000-0000-0000-00000000000B")
  private let accountC = makeUUID("10000000-0000-0000-0000-00000000000C")
  private let categoryA = makeUUID("30000000-0000-0000-0000-00000000000A")
  private let categoryB = makeUUID("30000000-0000-0000-0000-00000000000B")
  private let jointAccount = makeUUID("20000000-0000-0000-0000-000000000000")

  @Test
  func partialOwnerTransferDisposesOldestSourceLotsBeforeRetainedMove() async throws {
    let ledger = try await buildLedger(
      transactions: [
        buy(on: 0, account: accountA, shares: 40, cash: 400),
        buy(on: 10, account: accountA, shares: 60, cash: 1_200),
        transfer(on: 100, from: accountA, to: accountB, instrument: bhp, quantity: 100),
      ],
      accounts: [
        account(id: accountA, owners: [ownerA]),
        account(id: accountB, owners: [ownerA, ownerB]),
      ],
      conversionService: FakeConversionService.fixedRates([bhp.id: 30]))

    let ownerAResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerA)

    #expect(
      ownerAResult.events.count == 2,
      "owner A's taxable half must be disposed before the retained half moves, so FIFO spans the oldest lot and part of the next"
    )
    let oldestLotDisposal = try #require(ownerAResult.events.first)
    #expect(oldestLotDisposal.sellDate == day(100))
    #expect(oldestLotDisposal.acquiredDate == day(0))
    #expect(oldestLotDisposal.quantity == 40)
    #expect(oldestLotDisposal.costBasis == 400)
    #expect(oldestLotDisposal.proceeds == 1_200)
    #expect(oldestLotDisposal.gain == 800)
    #expect(oldestLotDisposal.taxOwnerId == ownerA)

    let laterLotDisposal = try #require(ownerAResult.events.dropFirst().first)
    #expect(laterLotDisposal.sellDate == day(100))
    #expect(laterLotDisposal.acquiredDate == day(10))
    #expect(laterLotDisposal.quantity == 10)
    #expect(laterLotDisposal.costBasis == 200)
    #expect(laterLotDisposal.proceeds == 300)
    #expect(laterLotDisposal.gain == 100)
    #expect(laterLotDisposal.taxOwnerId == ownerA)

    #expect(
      ownerAResult.openLots.count == 1,
      "owner A's retained half should move only the remaining later lot after the disposal drains the oldest source lot"
    )
    let retainedLot = try #require(ownerAResult.openLots.first)
    #expect(retainedLot.account == accountB)
    #expect(retainedLot.acquiredDate == day(10))
    #expect(retainedLot.remainingQuantity == 50)
    #expect(retainedLot.costPerUnit == 20)
    #expect(retainedLot.taxOwnerId == ownerA)
  }

  @Test
  func overlappingOwnerPartialSaleKeepsMovedLotAheadOfMarketAcquisition()
    async throws
  {
    let ledger = try await buildLedger(
      transactions: [
        buy(on: 0, account: jointAccount, shares: 100, cash: 1_000),
        transfer(on: 100, from: jointAccount, to: accountB, instrument: bhp, quantity: 100),
        sell(on: 200, account: accountB, shares: 25, proceeds: 1_000),
      ],
      accounts: [
        account(id: jointAccount, owners: [ownerA, ownerB]),
        account(id: accountB, owners: [ownerB]),
      ],
      conversionService: FakeConversionService.fixedRates([bhp.id: 30]))

    let ownerBResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerB)

    #expect(
      ownerBResult.events.count == 1,
      "owner B should realise only the later sale; the transfer overlap itself is not taxable to B")
    let sale = try #require(ownerBResult.events.first)
    #expect(sale.sellDate == day(200))
    #expect(sale.acquiredDate == day(0))
    #expect(sale.quantity == 25)
    #expect(sale.costBasis == 250)
    #expect(sale.proceeds == 1_000)
    #expect(sale.gain == 750)
    #expect(sale.taxOwnerId == ownerB)

    #expect(
      ownerBResult.openLots.count == 2,
      "B's partially sold moved lot should remain ahead of the transfer-market acquisition lot")
    let movedOlderLot = try #require(ownerBResult.openLots.first)
    #expect(movedOlderLot.account == accountB)
    #expect(movedOlderLot.acquiredDate == day(0))
    #expect(movedOlderLot.remainingQuantity == 25)
    #expect(movedOlderLot.costPerUnit == 10)
    #expect(movedOlderLot.taxOwnerId == ownerB)

    let marketValueLot = try #require(ownerBResult.openLots.dropFirst().first)
    #expect(marketValueLot.account == accountB)
    #expect(marketValueLot.acquiredDate == day(100))
    #expect(marketValueLot.remainingQuantity == 50)
    #expect(marketValueLot.costPerUnit == 30)
    #expect(marketValueLot.taxOwnerId == ownerB)
  }

  @Test
  func failedPartialOwnerTransferMarketValueOnlyMakesSourceOnlyOwnerUnavailable()
    async throws
  {
    let ledger = try await buildLedger(
      transactions: [
        buy(on: 0, account: jointAccount, shares: 100, cash: 4_000),
        transfer(on: 100, from: jointAccount, to: accountC, instrument: bhp, quantity: 100),
      ],
      accounts: [
        account(id: jointAccount, owners: [ownerA, ownerB]),
        account(id: accountC, owners: [ownerB, ownerC]),
      ],
      conversionService: FakeConversionService.failingInstruments([bhp.id]))
    let transferInterval = day(50)..<day(150)

    let ownerAIntervalResult = CapitalGainsCalculator.compute(
      ledger: ledger,
      sellDateInterval: transferInterval,
      ownerId: ownerA)
    let ownerBIntervalResult = CapitalGainsCalculator.compute(
      ledger: ledger,
      sellDateInterval: transferInterval,
      ownerId: ownerB)
    let ownerCIntervalResult = CapitalGainsCalculator.compute(
      ledger: ledger,
      sellDateInterval: transferInterval,
      ownerId: ownerC)

    #expect(ownerAIntervalResult.events.isEmpty)
    #expect(ownerAIntervalResult.totalRealizedGain == 0)
    #expect(
      ownerAIntervalResult.hasUnavailableData,
      "source-only owner A has a transfer-date disposal whose market value failed")
    #expect(ownerAIntervalResult.unavailableInstruments == [bhp])
    #expect(ownerAIntervalResult.unavailableInstrumentIds == [bhp.id])

    #expect(ownerBIntervalResult.events.isEmpty)
    #expect(ownerBIntervalResult.totalRealizedGain == 0)
    #expect(
      ownerBIntervalResult.hasUnavailableData == false,
      "overlapping owner B has no realised disposal in the interval, so the failed transfer market value must not make B's zero CGT unavailable"
    )
    #expect(ownerBIntervalResult.unavailableInstruments.isEmpty)
    #expect(ownerBIntervalResult.unavailableInstrumentIds.isEmpty)

    #expect(ownerCIntervalResult.events.isEmpty)
    #expect(ownerCIntervalResult.totalRealizedGain == 0)
    #expect(
      ownerCIntervalResult.hasUnavailableData == false,
      "destination-only owner C has no realised disposal in the interval, so the failed transfer market value must not make C's zero CGT unavailable"
    )
    #expect(ownerCIntervalResult.unavailableInstruments.isEmpty)
    #expect(ownerCIntervalResult.unavailableInstrumentIds.isEmpty)
  }

  @Test
  func failedPartialOwnerTransferStillMovesOverlappingOwnerCostBasis() async throws {
    let ledger = try await buildLedger(
      transactions: [
        buy(on: 0, account: jointAccount, shares: 100, cash: 1_000),
        transfer(on: 100, from: jointAccount, to: accountB, instrument: bhp, quantity: 100),
        sell(on: 200, account: accountB, shares: 25, proceeds: 1_000),
      ],
      accounts: [
        account(id: jointAccount, owners: [ownerA, ownerB]),
        account(id: accountB, owners: [ownerB, ownerC]),
      ],
      conversionService: FakeConversionService.failingInstruments([bhp.id]))

    let ownerBResult = CapitalGainsCalculator.compute(
      ledger: ledger,
      sellDateInterval: day(150)..<day(250),
      ownerId: ownerB)

    #expect(ownerBResult.hasUnavailableData == false)
    #expect(ownerBResult.unavailableInstruments.isEmpty)
    let sale = try #require(ownerBResult.events.first)
    #expect(ownerBResult.events.count == 1)
    #expect(sale.sellDate == day(200))
    #expect(sale.acquiredDate == day(0))
    #expect(sale.quantity == 12.5)
    #expect(sale.costBasis == 125)
    #expect(sale.proceeds == 500)
    #expect(sale.gain == 375)
    #expect(sale.taxOwnerId == ownerB)
  }

  @Test
  func failedPartialOwnerTransferMakesDestinationOnlyFutureSaleUnavailable() async throws {
    let ledger = try await buildLedger(
      transactions: [
        buy(on: 0, account: jointAccount, shares: 100, cash: 4_000),
        transfer(on: 100, from: jointAccount, to: accountC, instrument: bhp, quantity: 100),
        sell(on: 200, account: accountC, shares: 50, proceeds: 3_000),
      ],
      accounts: [
        account(id: jointAccount, owners: [ownerA, ownerB]),
        account(id: accountC, owners: [ownerB, ownerC]),
      ],
      conversionService: FakeConversionService.failingInstruments([bhp.id]))

    let ownerBResult = CapitalGainsCalculator.compute(
      ledger: ledger,
      sellDateInterval: day(150)..<day(250),
      ownerId: ownerB)
    let ownerCResult = CapitalGainsCalculator.compute(
      ledger: ledger,
      sellDateInterval: day(150)..<day(250),
      ownerId: ownerC)

    #expect(ownerBResult.hasUnavailableData == false)
    let ownerBSale = try #require(ownerBResult.events.first)
    #expect(ownerBResult.events.count == 1)
    #expect(ownerBSale.quantity == 25)
    #expect(ownerBSale.costBasis == 1_000)
    #expect(ownerBSale.proceeds == 1_500)
    #expect(ownerBSale.gain == 500)
    #expect(ownerBSale.taxOwnerId == ownerB)

    #expect(ownerCResult.events.isEmpty)
    #expect(ownerCResult.hasUnavailableData)
    #expect(ownerCResult.unavailableInstruments == [bhp])
    #expect(ownerCResult.unavailableInstrumentIds == [bhp.id])
  }

  @Test
  func failedSameAccountCustomTradeUsesLegLevelCategoryOwnersForUnavailableData()
    async throws
  {
    let spam = Instrument.crypto(
      chainId: 10,
      contractAddress: "0x21841eb46ccce03ebe57b4ee6eb547f31dfde152",
      symbol: "SPAM",
      name: "Spam Token",
      decimals: 18)
    let ledger = try await buildLedger(
      transactions: [
        Transaction(
          id: makeUUID("61000000-0000-0000-0000-000000000000"),
          date: day(100),
          legs: [
            leg(account: accountA, instrument: spam, quantity: -10, categoryId: categoryA),
            leg(account: accountA, instrument: bhp, quantity: 1, categoryId: categoryB),
          ])
      ],
      accounts: [account(id: accountA, owners: [ownerC])],
      categories: [
        category(id: categoryA, owners: [ownerA]),
        category(id: categoryB, owners: [ownerB]),
      ],
      conversionService: FakeConversionService.failingInstruments([spam.id]))

    let ownerAResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerA)
    let ownerBResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerB)
    let ownerCResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: ownerC)

    #expect(ownerAResult.hasUnavailableData)
    #expect(ownerAResult.unavailableInstruments == [spam])
    #expect(ownerBResult.hasUnavailableData)
    #expect(ownerBResult.unavailableInstruments == [bhp])
    #expect(ownerCResult.hasUnavailableData == false)
    #expect(ownerCResult.unavailableInstruments.isEmpty)
  }
}

extension TransferOwnerRegressionTests {
  private func buildLedger(
    transactions: [Transaction],
    accounts: [Account],
    categories: [Moolah.Category] = [],
    conversionService: any InstrumentConversionService = FakeConversionService.fixedRates([:])
  ) async throws -> HoldingsCostLedger {
    let resolver = TaxOwnershipResolver(
      profileDefaultOwnerId: defaultOwner,
      accounts: accounts,
      categories: categories)
    return try await HoldingsCostLedger.build(
      transactions: transactions,
      referenceCurrency: aud,
      conversionService: conversionService,
      taxOwnershipResolver: resolver)
  }

  private func account(id: UUID, owners: [UUID]) -> Account {
    Account(
      id: id,
      name: "CGT transfer account \(id.uuidString)",
      type: .investment,
      instrument: aud,
      taxOwnerIds: owners)
  }

  private func category(id: UUID, owners: [UUID]) -> Moolah.Category {
    Moolah.Category(
      id: id,
      name: "CGT transfer category \(id.uuidString)",
      isTaxReportable: true,
      taxOwnerIds: owners)
  }

  private func buy(
    on dayNumber: Int,
    account: UUID,
    shares: Decimal,
    cash: Decimal
  ) -> Transaction {
    Transaction(
      id: makeUUID("31000000-0000-0000-0000-\(padded(dayNumber))000000"),
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
      id: makeUUID("41000000-0000-0000-0000-\(padded(dayNumber))000000"),
      date: day(dayNumber),
      legs: [
        leg(account: account, instrument: bhp, quantity: -shares),
        leg(account: account, instrument: aud, quantity: proceeds),
      ])
  }

  private func transfer(
    on dayNumber: Int,
    from sourceAccount: UUID,
    to destinationAccount: UUID,
    instrument: Instrument,
    quantity: Decimal
  ) -> Transaction {
    Transaction(
      id: makeUUID("51000000-0000-0000-0000-\(padded(dayNumber))000000"),
      date: day(dayNumber),
      legs: [
        leg(account: sourceAccount, instrument: instrument, quantity: -quantity, type: .transfer),
        leg(
          account: destinationAccount, instrument: instrument, quantity: quantity,
          type: .transfer),
      ])
  }

  private func leg(
    account: UUID,
    instrument: Instrument,
    quantity: Decimal,
    type: TransactionType = .trade,
    categoryId: UUID? = nil
  ) -> TransactionLeg {
    TransactionLeg(
      accountId: account,
      instrument: instrument,
      quantity: quantity,
      type: type,
      categoryId: categoryId)
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

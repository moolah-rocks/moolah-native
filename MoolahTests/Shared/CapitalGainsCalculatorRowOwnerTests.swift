import Foundation
import Testing

@testable import Moolah

@Suite("CapitalGainsCalculator row owner defaults")
struct CapitalGainsCalculatorRowOwnerTests {
  let aud = Instrument.AUD
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let defaultOwner = makeUUID("00000000-0000-0000-0000-000000000001")
  let accountA = makeUUID("10000000-0000-0000-0000-00000000000A")
  let accountC = makeUUID("10000000-0000-0000-0000-00000000000C")

  @Test
  func rowBasedLedgerResolvesImplicitDefaultOwnerTransfersAsSameOwner() async throws {
    let ledger = try await buildLedger(
      legRows: implicitDefaultTransferRows(),
      accounts: [
        account(id: accountA, owners: []),
        account(id: accountC, owners: [defaultOwner]),
      ])

    let defaultOwnerResult = CapitalGainsCalculator.compute(ledger: ledger, ownerId: defaultOwner)

    #expect(defaultOwnerResult.events.count == 1)
    let saleEvent = try #require(defaultOwnerResult.events.first)
    #expect(saleEvent.sellDate == day(200))
    #expect(saleEvent.acquiredDate == day(0))
    #expect(saleEvent.quantity == 100)
    #expect(saleEvent.costBasis == 4_000)
    #expect(saleEvent.proceeds == 6_000)
    #expect(saleEvent.gain == 2_000)
    #expect(saleEvent.taxOwnerId == defaultOwner)
  }
}

extension CapitalGainsCalculatorRowOwnerTests {
  func implicitDefaultTransferRows() -> [CostBasisEventLegRow] {
    let buy = makeUUID("30000000-0000-0000-0000-000000000010")
    let transfer = makeUUID("50000000-0000-0000-0000-000000000110")
    let sell = makeUUID("40000000-0000-0000-0000-000000000210")
    return [
      row(transactionId: buy, on: 0, account: accountA, instrument: aud, quantity: -4_000),
      row(transactionId: buy, on: 0, account: accountA, instrument: bhp, quantity: 100),
      row(
        transactionId: transfer, on: 100, account: accountA, instrument: bhp,
        quantity: -100, type: .transfer),
      row(
        transactionId: transfer, on: 100, account: accountC, instrument: bhp,
        quantity: 100, type: .transfer, taxOwnerIds: [defaultOwner]),
      row(
        transactionId: sell, on: 200, account: accountC, instrument: bhp,
        quantity: -100, taxOwnerIds: [defaultOwner]),
      row(
        transactionId: sell, on: 200, account: accountC, instrument: aud,
        quantity: 6_000, taxOwnerIds: [defaultOwner]),
    ]
  }

  func buildLedger(
    legRows: [CostBasisEventLegRow],
    accounts: [Account]
  ) async throws -> HoldingsCostLedger {
    let resolver = TaxOwnershipResolver(
      profileDefaultOwnerId: defaultOwner,
      accounts: accounts,
      categories: [])
    return try await HoldingsCostLedger.build(
      legRows: legRows,
      referenceCurrency: aud,
      conversionService: FakeConversionService.fixedRates([bhp.id: 50]),
      taxOwnershipResolver: resolver)
  }

  func account(id: UUID, owners: [UUID]) -> Account {
    Account(
      id: id,
      name: "CGT row account \(id.uuidString)",
      type: .investment,
      instrument: aud,
      taxOwnerIds: owners)
  }

  func row(
    transactionId: UUID,
    on dayNumber: Int,
    account: UUID,
    instrument: Instrument,
    quantity: Decimal,
    type: TransactionType = .trade,
    taxOwnerIds: [UUID] = []
  ) -> CostBasisEventLegRow {
    CostBasisEventLegRow(
      id: UUID(),
      transactionId: transactionId,
      date: day(dayNumber),
      accountId: account,
      instrument: instrument,
      quantity: quantity,
      type: type,
      sortOrder: 0,
      taxOwnerIds: taxOwnerIds)
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
}

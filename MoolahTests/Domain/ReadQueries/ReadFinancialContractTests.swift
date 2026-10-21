import Foundation
import Testing

@testable import Moolah

struct ReadFinancialContractTests {
  @Test
  func quantitiesRemainExactSignedDecimalStringsOnTheWire() throws {
    let quantity = try #require(Decimal(string: "-0.00000001"))
    let dto = ReadQuantityDTO(quantity: quantity, instrument: .defaultTestInstrument)
    let data = try JSONEncoder().encode(dto)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["quantity"] as? String == "-0.00000001")
    #expect(dto.instrument.storageScale == 8)
  }

  @Test
  func notesAreAbsentUnlessTheCallerExplicitlyPermitsThem() async throws {
    let (backend, _) = try TestBackend.create()
    let transaction = Transaction(
      date: Date(timeIntervalSince1970: 1_777_680_000),
      payee: "A payee is untrusted data",
      notes: "Private note",
      legs: [])
    _ = try await backend.transactions.create(transaction)
    let repository = try #require(backend.readQueries)
    let ordinary = try await repository.transaction(id: transaction.id)
    let permitted = try await repository.transaction(id: transaction.id, includeNotes: true)
    let ordinaryData = try JSONEncoder().encode(ordinary.items)
    #expect(!(String(data: ordinaryData, encoding: .utf8) ?? "").contains("Private note"))
    #expect(ordinary.items.first?.notes == nil)
    #expect(permitted.items.first?.notes == "Private note")
  }

  @Test
  func multiInstrumentBalancesStaySeparateAndExcludeScheduledEntries() async throws {
    let (backend, _) = try TestBackend.create()
    let account = Account(name: "Mixed holdings", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)
    let euro = Instrument.fiat(code: "EUR")
    let date = Date(timeIntervalSince1970: 1_777_680_000)
    _ = try await backend.transactions.create(
      Transaction(
        date: date,
        legs: [
          TransactionLeg(
            accountId: account.id,
            instrument: .defaultTestInstrument,
            quantity: -25,
            type: .openingBalance),
          TransactionLeg(
            accountId: account.id,
            instrument: euro,
            quantity: 100,
            type: .openingBalance),
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: date,
        recurPeriod: .once,
        legs: [
          TransactionLeg(accountId: account.id, instrument: euro, quantity: 999, type: .income)
        ]))
    let repository = try #require(backend.readQueries)
    let balances = try await repository.balances(accountIDs: [account.id])
    let positions = try #require(balances.items.first?.positions)
    #expect(positions.count == 2)
    #expect(positions.first { $0.instrument.id == euro.id }?.quantity == "100")
    #expect(
      positions.first { $0.instrument.id == Instrument.defaultTestInstrument.id }?.quantity == "-25"
    )
  }

  @Test
  func searchFiltersMatchOneLegAndReturnEveryLegWithMatchMarkers() async throws {
    let (backend, _) = try TestBackend.create()
    let first = Account(name: "First", type: .bank, instrument: .defaultTestInstrument)
    let second = Account(name: "Second", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(first)
    _ = try await backend.accounts.create(second)
    let category = Category(id: UUID(), name: "Category")
    _ = try await backend.categories.create(category)
    let date = Date(timeIntervalSince1970: 1_777_680_000)
    let transaction = Transaction(
      date: date,
      legs: [
        TransactionLeg(
          accountId: first.id,
          instrument: .defaultTestInstrument,
          quantity: -10,
          type: .expense,
          categoryId: category.id),
        TransactionLeg(
          accountId: second.id,
          instrument: .defaultTestInstrument,
          quantity: 10,
          type: .transfer),
      ])
    _ = try await backend.transactions.create(transaction)
    let repository = try #require(backend.readQueries)
    let search = try ReadTransactionSearch(
      range: ReadDateRange(
        interval: date..<date.addingTimeInterval(1),
        timeZone: .utc),
      accountIDs: [first.id],
      categoryIDs: [category.id])
    let matching = try await repository.transactions(search: search, page: ReadPageRequest())
    let returned = try #require(matching.items.first)
    #expect(returned.legs.count == 2)
    #expect(returned.legs.filter(\.matchesFilters).map(\.accountID) == [first.id])
    let crossedSearch = try ReadTransactionSearch(
      range: ReadDateRange(
        interval: date..<date.addingTimeInterval(1),
        timeZone: .utc),
      accountIDs: [second.id],
      categoryIDs: [category.id])
    let crossed = try await repository.transactions(search: crossedSearch, page: ReadPageRequest())
    #expect(crossed.items.isEmpty)
  }
}

extension ReadFinancialContractTests {
  @Test
  func earmarkDenominationRemainsExplicitWithNoTargetOrPositions() async throws {
    let (backend, _) = try TestBackend.create(instrument: .AUD)
    let earmark = Earmark(name: "USD reserve", instrument: .USD)
    _ = try await backend.earmarks.create(earmark)
    let repository = try #require(backend.readQueries)
    let page = try await repository.earmarks(page: ReadPageRequest())
    let result = try #require(page.items.first)
    #expect(result.primaryInstrument.id == "USD")
    #expect(result.target == nil)
    #expect(result.positions.isEmpty)
  }

  @Test
  func cancellingLegQuantitiesDropZeroNativePositions() async throws {
    let (backend, _) = try TestBackend.create()
    let instrument = Instrument.defaultTestInstrument
    let account = Account(name: "Zero", type: .bank, instrument: instrument)
    let earmark = Earmark(name: "Zero", instrument: instrument)
    _ = try await backend.accounts.create(account)
    _ = try await backend.earmarks.create(earmark)
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(timeIntervalSince1970: 1_777_680_000),
        legs: [
          TransactionLeg(
            accountId: account.id,
            instrument: instrument,
            quantity: 10,
            type: .income,
            earmarkId: earmark.id),
          TransactionLeg(
            accountId: account.id,
            instrument: instrument,
            quantity: -10,
            type: .expense,
            earmarkId: earmark.id),
        ]))
    let repository = try #require(backend.readQueries)
    let balances = try await repository.balances(accountIDs: [account.id])
    let earmarks = try await repository.earmarks(page: ReadPageRequest())
    #expect(balances.items.first?.positions.isEmpty == true)
    #expect(earmarks.items.first?.positions.isEmpty == true)
  }
}

extension ReadFinancialContractTests {
  @Test
  func positionsSupportMultipleOwnersInOneBoundedQuery() async throws {
    let (backend, _) = try TestBackend.create()
    let instrument = Instrument.defaultTestInstrument
    let first = Account(name: "First", type: .bank, instrument: instrument)
    let second = Account(name: "Second", type: .bank, instrument: instrument)
    let firstEarmark = Earmark(name: "First", instrument: instrument)
    let secondEarmark = Earmark(name: "Second", instrument: instrument)
    _ = try await backend.accounts.create(first)
    _ = try await backend.accounts.create(second)
    _ = try await backend.earmarks.create(firstEarmark)
    _ = try await backend.earmarks.create(secondEarmark)
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(timeIntervalSince1970: 1_777_680_000),
        legs: [
          TransactionLeg(
            accountId: first.id, instrument: instrument, quantity: 10,
            type: .income, earmarkId: firstEarmark.id),
          TransactionLeg(
            accountId: second.id, instrument: instrument, quantity: 20,
            type: .income, earmarkId: secondEarmark.id),
        ]))
    let repository = try #require(backend.readQueries)
    let balances = try await repository.balances(accountIDs: [first.id, second.id])
    let earmarks = try await repository.earmarks(page: ReadPageRequest())
    #expect(balances.items.count == 2)
    #expect(earmarks.items.count == 2)
    #expect(Set(balances.items.flatMap(\.positions).map(\.quantity)) == ["10", "20"])
    #expect(Set(earmarks.items.flatMap(\.positions).map(\.quantity)) == ["10", "20"])
  }
}

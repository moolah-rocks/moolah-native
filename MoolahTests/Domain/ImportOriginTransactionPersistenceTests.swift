import Foundation
import Testing

@testable import Moolah

@Suite("TransactionRepository preserves ImportOrigin")
struct ImportOriginTransactionPersistenceTests {

  @Test("create + fetch preserves every ImportOrigin field")
  func roundTrip() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    let sessionId = UUID()
    let origin = ImportOrigin(
      rawDescription: "COFFEE @ SHOP",
      bankReference: "REF-42",
      rawAmount: dec("-12.34"),
      rawBalance: dec("500.00"),
      importedAt: Date(timeIntervalSince1970: 1_700_000_000),
      importSessionId: sessionId,
      sourceFilename: "cba.csv",
      parserIdentifier: "generic-bank")
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank,
        instrument: .AUD, positions: [], position: 0, isHidden: false),
      openingBalance: nil)
    let transaction = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD,
          quantity: dec("-12.34"), type: .expense,
          categoryId: nil, earmarkId: nil)
      ],
      importOrigin: .single(origin))
    _ = try await backend.transactions.create(transaction)

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0, pageSize: 10)
    #expect(page.transactions.first?.importOrigin == .single(origin))
  }

  @Test("create + fetch of a transaction without importOrigin returns nil")
  func nilOriginRoundTrip() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank,
        instrument: .AUD, positions: [], position: 0, isHidden: false),
      openingBalance: nil)
    let transaction = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD,
          quantity: dec("-12.34"), type: .expense,
          categoryId: nil, earmarkId: nil)
      ])
    _ = try await backend.transactions.create(transaction)

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0, pageSize: 10)
    #expect(page.transactions.first?.importOrigin == nil)
  }

  @Test("update can set or clear importOrigin after create")
  func updateSetAndClear() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank,
        instrument: .AUD, positions: [], position: 0, isHidden: false),
      openingBalance: nil)
    var transaction = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD,
          quantity: dec("-12.34"), type: .expense,
          categoryId: nil, earmarkId: nil)
      ])
    _ = try await backend.transactions.create(transaction)

    let sessionId = UUID()
    let origin = ImportOrigin(
      rawDescription: "Updated",
      bankReference: nil,
      rawAmount: dec("-12.34"),
      rawBalance: nil,
      importedAt: Date(timeIntervalSince1970: 1_700_000_000),
      importSessionId: sessionId,
      sourceFilename: nil,
      parserIdentifier: "generic-bank")
    transaction.importOrigin = .single(origin)
    _ = try await backend.transactions.update(transaction)

    var page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0, pageSize: 10)
    #expect(page.transactions.first?.importOrigin == .single(origin))

    transaction.importOrigin = nil
    _ = try await backend.transactions.update(transaction)
    page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0, pageSize: 10)
    #expect(page.transactions.first?.importOrigin == nil)
  }

  @Test("update can flip a single origin to merged")
  func updateSetsMergedOrigin() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = try await seededAccount(in: backend)
    let originA = outgoingOrigin()
    let originB = incomingOrigin()
    // Created as a plain `.single` origin so the update below must
    // flip the discriminator to "merged" and populate the incoming
    // columns — which a field-by-field `applyMetadata` would drop.
    var transaction = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000),
      payee: "Original payee",
      legs: [singleLeg(accountId: accountId)],
      importOrigin: .single(originA))
    _ = try await backend.transactions.create(transaction)

    transaction.payee = "Renamed payee"
    transaction.importOrigin = .merged(MergedImportOrigin(outgoing: originA, incoming: originB))
    _ = try await backend.transactions.update(transaction)

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0, pageSize: 10)
    let fetched = page.transactions.first
    #expect(fetched?.payee == "Renamed payee")
    #expect(
      fetched?.importOrigin == .merged(MergedImportOrigin(outgoing: originA, incoming: originB)))
  }

  @Test("update can flip a merged origin to single")
  func updateFlipsMergedToSingle() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = try await seededAccount(in: backend)
    let originA = outgoingOrigin()
    let originB = incomingOrigin()
    var transaction = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000),
      legs: [singleLeg(accountId: accountId)],
      importOrigin: .merged(MergedImportOrigin(outgoing: originA, incoming: originB)))
    _ = try await backend.transactions.create(transaction)

    transaction.importOrigin = .single(originA)
    _ = try await backend.transactions.update(transaction)

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0, pageSize: 10)
    #expect(page.transactions.first?.importOrigin == .single(originA))
  }

  // MARK: - Fixtures

  private func seededAccount(in backend: CloudKitBackend) async throws -> UUID {
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank,
        instrument: .AUD, positions: [], position: 0, isHidden: false),
      openingBalance: nil)
    return accountId
  }

  private func singleLeg(accountId: UUID) -> TransactionLeg {
    TransactionLeg(
      accountId: accountId, instrument: .AUD,
      quantity: dec("-50.00"), type: .expense,
      categoryId: nil, earmarkId: nil)
  }

  private func outgoingOrigin() -> ImportOrigin {
    ImportOrigin(
      rawDescription: "OUT @ A",
      bankReference: "REF-A",
      rawAmount: dec("-50.00"),
      rawBalance: dec("100.00"),
      importedAt: Date(timeIntervalSince1970: 1_700_000_000),
      importSessionId: UUID(),
      sourceFilename: "a.csv",
      parserIdentifier: "generic-bank")
  }

  private func incomingOrigin() -> ImportOrigin {
    ImportOrigin(
      rawDescription: "IN @ B",
      bankReference: "REF-B",
      rawAmount: dec("50.00"),
      rawBalance: dec("200.00"),
      importedAt: Date(timeIntervalSince1970: 1_700_000_100),
      importSessionId: UUID(),
      sourceFilename: "b.csv",
      parserIdentifier: "generic-bank")
  }
}

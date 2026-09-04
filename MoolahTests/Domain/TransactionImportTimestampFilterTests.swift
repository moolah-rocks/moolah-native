import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("TransactionRepository — import timestamp filter")
struct TransactionImportTimestampFilterTests {
  @Test("filters single-origin transactions by import timestamp")
  func filtersByImportedAtRange() async throws {
    let accountId = UUID()
    let sessionId = UUID()
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let recentOrigin = ImportOrigin(
      rawDescription: "recent",
      rawAmount: -10,
      importedAt: now.addingTimeInterval(-60),
      importSessionId: sessionId,
      parserIdentifier: "test")
    let oldOrigin = ImportOrigin(
      rawDescription: "old",
      rawAmount: -20,
      importedAt: now.addingTimeInterval(-172_800),
      importSessionId: sessionId,
      parserIdentifier: "test")
    let transactions = [
      Transaction(
        date: now.addingTimeInterval(-31_536_000),
        payee: "Recently imported old purchase",
        legs: [
          makeContractTestLeg(accountId: accountId, quantity: -10, type: .expense)
        ],
        importOrigin: .single(recentOrigin)),
      Transaction(
        date: now,
        payee: "Old import",
        legs: [
          makeContractTestLeg(accountId: accountId, quantity: -20, type: .expense)
        ],
        importOrigin: .single(oldOrigin)),
      Transaction(
        date: now,
        payee: "Manual",
        legs: [
          makeContractTestLeg(accountId: accountId, quantity: -30, type: .expense)
        ]),
    ]
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: transactions)

    let page = try await repository.fetch(
      filter: TransactionFilter(
        importedAtRange: now.addingTimeInterval(-86_400)...now),
      page: 0,
      pageSize: 50)

    #expect(page.transactions.map(\.payee) == ["Recently imported old purchase"])
  }

  @Test("includes legacy single origins without a discriminator")
  func includesLegacySingleOrigin() async throws {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let transaction = Transaction(
      date: now,
      payee: "Legacy import",
      legs: [
        makeContractTestLeg(accountId: UUID(), quantity: -10, type: .expense)
      ],
      importOrigin: .single(
        ImportOrigin(
          rawDescription: "legacy",
          rawAmount: -10,
          importedAt: now,
          importSessionId: UUID(),
          parserIdentifier: "test")))
    let pair = try TestBackend.create()
    TestBackend.seed(transactions: [transaction], in: pair.database)
    try await pair.database.write { database in
      try database.execute(
        sql: "UPDATE \"transaction\" SET import_origin_kind = NULL WHERE id = ?",
        arguments: [transaction.id])
    }

    let page = try await pair.backend.transactions.fetch(
      filter: TransactionFilter(importedAtRange: now.addingTimeInterval(-1)...now),
      page: 0,
      pageSize: 50)

    #expect(page.transactions.map(\.payee) == ["Legacy import"])
  }
}

import Foundation
import Testing

@testable import Moolah

@Suite("TransactionRepository — accountIds filter")
@MainActor
struct TxnRepoAccountIdsFilterTests {

  /// Seeds two accounts each with one expense, then asserts that filtering
  /// by a 2-element `accountIds` set returns both transactions while
  /// filtering by a single-element set returns one. Mirrors the
  /// `accountId` (singular) filter test shape but exercises the new
  /// multi-account branch added for `AccountGroup` detail views.
  @Test("filtering by accountIds union returns transactions from every member")
  func filtersByAccountIdsUnion() async throws {
    let (backend, _) = try TestBackend.create()

    let accountA = try await backend.accounts.create(
      Account(
        name: "Member A", type: .crypto,
        instrument: .defaultTestInstrument))
    let accountB = try await backend.accounts.create(
      Account(
        name: "Member B", type: .crypto,
        instrument: .defaultTestInstrument))
    let standalone = try await backend.accounts.create(
      Account(
        name: "Standalone", type: .crypto,
        instrument: .defaultTestInstrument))

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Member A txn",
        legs: [
          TransactionLeg(
            accountId: accountA.id, instrument: .defaultTestInstrument,
            quantity: -10, type: .expense)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Member B txn",
        legs: [
          TransactionLeg(
            accountId: accountB.id, instrument: .defaultTestInstrument,
            quantity: -20, type: .expense)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Standalone txn",
        legs: [
          TransactionLeg(
            accountId: standalone.id, instrument: .defaultTestInstrument,
            quantity: -30, type: .expense)
        ]))

    let unionFilter = TransactionFilter(accountIds: [accountA.id, accountB.id])
    let unionPage = try await backend.transactions.fetch(
      filter: unionFilter, page: 0, pageSize: 50)
    let payees = Set(unionPage.transactions.compactMap(\.payee))
    #expect(payees == ["Member A txn", "Member B txn"])

    let singleFilter = TransactionFilter(accountIds: [accountA.id])
    let singlePage = try await backend.transactions.fetch(
      filter: singleFilter, page: 0, pageSize: 50)
    #expect(singlePage.transactions.map(\.payee) == ["Member A txn"])
  }

  @Test("empty accountIds set is treated as no account filter")
  func emptyAccountIdsActsAsNoFilter() async throws {
    let (backend, _) = try TestBackend.create()
    let account = try await backend.accounts.create(
      Account(name: "A", type: .bank, instrument: .defaultTestInstrument))
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Only txn",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -5, type: .expense)
        ]))

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountIds: []), page: 0, pageSize: 50)
    #expect(page.transactions.count == 1)
  }

  @Test("accountId and accountIds OR together")
  func accountIdAndAccountIdsUnion() async throws {
    let (backend, _) = try TestBackend.create()
    let accountA = try await backend.accounts.create(
      Account(name: "A", type: .bank, instrument: .defaultTestInstrument))
    let accountB = try await backend.accounts.create(
      Account(name: "B", type: .bank, instrument: .defaultTestInstrument))

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "A txn",
        legs: [
          TransactionLeg(
            accountId: accountA.id, instrument: .defaultTestInstrument,
            quantity: -10, type: .expense)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "B txn",
        legs: [
          TransactionLeg(
            accountId: accountB.id, instrument: .defaultTestInstrument,
            quantity: -20, type: .expense)
        ]))

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountA.id, accountIds: [accountB.id]),
      page: 0, pageSize: 50)
    #expect(Set(page.transactions.compactMap(\.payee)) == ["A txn", "B txn"])
  }
}

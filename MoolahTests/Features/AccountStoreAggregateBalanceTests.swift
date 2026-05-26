import Foundation
import Testing

@testable import Moolah

@Suite("AccountStore — aggregateBalance")
@MainActor
struct AccountStoreAggregateBalanceTests {

  /// Two single-instrument accounts: aggregate sums to the total in the
  /// target instrument.
  @Test("sums converted balances across N accounts")
  func sumsAcrossAccounts() async throws {
    let (backend, database) = try TestBackend.create()
    let memberA = Account(
      id: UUID(), name: "A", type: .crypto,
      instrument: .defaultTestInstrument)
    let memberB = Account(
      id: UUID(), name: "B", type: .crypto,
      instrument: .defaultTestInstrument)
    TestBackend.seed(accounts: [memberA, memberB], in: database)
    TestBackend.seed(
      transactions: [
        Transaction(
          date: Date(),
          legs: [
            TransactionLeg(
              accountId: memberA.id,
              instrument: .defaultTestInstrument,
              quantity: dec("100.00"),
              type: .openingBalance)
          ]),
        Transaction(
          date: Date(),
          legs: [
            TransactionLeg(
              accountId: memberB.id,
              instrument: .defaultTestInstrument,
              quantity: dec("250.00"),
              type: .openingBalance)
          ]),
      ], in: database)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.convertedBalances.count == 2 },
      description: "balances converted")

    let aggregate = try await store.aggregateBalance(
      for: [memberA.id, memberB.id], in: .defaultTestInstrument)
    let amount = try #require(aggregate)
    #expect(amount.quantity == dec("350.00"))
    #expect(amount.instrument == .defaultTestInstrument)
  }

  /// A 1-element id list collapses to the single account's converted
  /// balance — same code path serves single-account headers.
  @Test("1-element id list returns single account's balance")
  func singleAccountCase() async throws {
    let (backend, database) = try TestBackend.create()
    let account = Account(
      id: UUID(), name: "Solo", type: .bank,
      instrument: .defaultTestInstrument)
    TestBackend.seed(accounts: [account], in: database)
    TestBackend.seed(
      transactions: [
        Transaction(
          date: Date(),
          legs: [
            TransactionLeg(
              accountId: account.id,
              instrument: .defaultTestInstrument,
              quantity: dec("400.00"),
              type: .openingBalance)
          ])
      ], in: database)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.convertedBalances[account.id] != nil },
      description: "balance converted")

    let aggregate = try await store.aggregateBalance(
      for: [account.id], in: .defaultTestInstrument)
    let amount = try #require(aggregate)
    #expect(amount.quantity == dec("400.00"))
  }

  /// Empty id list returns nil — the caller renders an "unavailable"
  /// state for a zero-member group.
  @Test("empty id list returns nil")
  func emptyIdListReturnsNil() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()

    let aggregate = try await store.aggregateBalance(
      for: [], in: .defaultTestInstrument)
    #expect(aggregate == nil)
  }

  /// Unknown ids → nil (don't silently undercount when a member is
  /// transiently absent from the store snapshot during sync).
  @Test("unknown ids return nil")
  func unknownIdsReturnNil() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()

    let aggregate = try await store.aggregateBalance(
      for: [UUID()], in: .defaultTestInstrument)
    #expect(aggregate == nil)
  }
}

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Shared fixtures for the TransactionStore test suites
/// (`TransactionStoreLoadingTests`, `TransactionStoreCRUDTests`, etc.).
@MainActor
enum TransactionStoreTestSupport {
  /// A seeded account paired with its opening balance. Used by `makeStores` to
  /// populate the in-memory store before running a scenario.
  struct SeededAccount {
    let account: Account
    let openingBalance: InstrumentAmount
  }

  /// Helper to create an Account + opening balance pair for seeding.
  static func acct(
    id: UUID,
    name: String,
    type: AccountType = .bank,
    balance: Decimal,
    valuationMode: ValuationMode = .recordedValue
  ) -> SeededAccount {
    SeededAccount(
      account: Account(
        id: id, name: name, type: type, instrument: .defaultTestInstrument,
        valuationMode: valuationMode),
      openingBalance: InstrumentAmount(quantity: balance, instrument: .defaultTestInstrument)
    )
  }

  static func makeDate(_ string: String) throws -> Date {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return try #require(formatter.date(from: string))
  }

  static func seedTransactions(count: Int, accountId: UUID) throws -> [Transaction] {
    try (0..<count).map { index in
      Transaction(
        date: try makeDate("2024-01-\(String(format: "%02d", min(index + 1, 28)))"),
        payee: "Payee \(index)",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: Instrument.defaultTestInstrument,
            quantity: Decimal(-(index + 1) * 1000) / 100,
            type: .expense
          )
        ]
      )
    }
  }

  /// Bundle of stores returned by `makeStores` so call sites can grab whichever
  /// they need by name rather than positional tuple access.
  struct Stores {
    let transactions: TransactionStore
    let accounts: AccountStore
    let earmarks: EarmarkStore
  }

  static func makeStores(
    backend: CloudKitBackend,
    database: any DatabaseWriter,
    accounts: [SeededAccount] = [],
    earmarks: [Earmark] = []
  ) async throws -> Stores {
    if !accounts.isEmpty {
      let tuples = accounts.map { ($0.account, $0.openingBalance) }
      TestBackend.seed(accounts: tuples, in: database)
    }
    if !earmarks.isEmpty {
      TestBackend.seed(earmarks: earmarks, in: database)
    }
    let accountStore = AccountStore(
      repository: backend.accounts,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )
    let earmarkStore = EarmarkStore(
      repository: backend.earmarks,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )
    // `AccountStore` and `EarmarkStore` are both reactive — wait for an
    // observation emission that contains the seeded rows before any
    // TransactionStore code path that depends on them being visible
    // runs. Without seeded entries the first emission is enough.
    if accounts.isEmpty {
      try await accountStore.waitForFirstEmission()
    } else {
      let expectedCount = accounts.count
      try await accountStore.waitForNextEmission(
        matching: { $0.accounts.count == expectedCount },
        description: "seeded accounts observable"
      )
    }
    if earmarks.isEmpty {
      try await earmarkStore.waitForFirstEmission()
    } else {
      let expectedCount = earmarks.count
      try await earmarkStore.waitForNextEmission(
        matching: { $0.earmarks.count == expectedCount },
        description: "seeded earmarks observable"
      )
    }
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )
    return Stores(transactions: store, accounts: accountStore, earmarks: earmarkStore)
  }
}

/// Test-only helpers for awaiting the reactive observation tick after a
/// mutation. Mutations are pass-through under the reactive design, so
/// the store doesn't update its `transactions` array until the next
/// `repository.observe(...)` emission lands. Existing pre-migration
/// tests assumed synchronous local state; these helpers bridge that
/// gap by awaiting the next emission.
extension TransactionStore {
  /// Awaits the next observation emission and asserts no timeout. Used
  /// by tests that want a one-line "do mutation; await emission"
  /// pattern rather than calling `waitForNextEmission(matching:)` with
  /// a custom predicate.
  func awaitNextSyncRefresh(timeout: Duration = .seconds(10)) async throws {
    try await waitForFirstEmission(timeout: timeout)
  }

  /// Convenience for "do mutation, then await an emission whose
  /// `transactions.count` matches `expected`". Useful for the most
  /// common test shape after a create/update/delete.
  func awaitTransactionCount(
    _ expected: Int, timeout: Duration = .seconds(10)
  ) async throws {
    if transactions.count == expected { return }
    try await waitForNextEmission(
      matching: { $0.transactions.count == expected },
      description: "transactions.count == \(expected)",
      timeout: timeout
    )
  }
}

/// In-memory `TransactionRepository` whose every method throws, used by
/// createDefault tests that exercise the failure path. Lives in support so it
/// can be shared across split suites.
struct FailingTransactionRepository: TransactionRepository {
  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
    throw BackendError.networkUnavailable
  }

  func fetchAll(filter: TransactionFilter) async throws -> [Transaction] {
    throw BackendError.networkUnavailable
  }

  func observe(
    filter: TransactionFilter, page: Int, pageSize: Int
  ) -> AsyncStream<TransactionPage> {
    AsyncStream { $0.finish() }
  }

  func observeAll(filter: TransactionFilter) -> AsyncStream<[Transaction]> {
    AsyncStream { $0.finish() }
  }

  func observeErrors() -> AsyncStream<any Error> {
    AsyncStream { $0.finish() }
  }

  func create(_ transaction: Transaction) async throws -> Transaction {
    throw BackendError.networkUnavailable
  }

  func createMany(_ transactions: [Transaction]) async throws -> [Transaction] {
    throw BackendError.networkUnavailable
  }

  func update(_ transaction: Transaction) async throws -> Transaction {
    throw BackendError.networkUnavailable
  }

  func delete(id: UUID) async throws {
    throw BackendError.networkUnavailable
  }

  func replace(deletingIds: [UUID], creating: [Transaction]) async throws -> [Transaction] {
    throw BackendError.networkUnavailable
  }

  func fetchPayeeSuggestions(
    prefix: String, excludingTransactionId: UUID?
  ) async throws -> [String] {
    throw BackendError.networkUnavailable
  }

  func legs(matchingExternalId externalId: String) async throws -> [TransactionLeg] {
    throw BackendError.networkUnavailable
  }

  func transactions(touchingExternalIds externalIds: Set<String>) async throws -> [Transaction] {
    throw BackendError.networkUnavailable
  }

  func legExists(accountId: UUID, externalId: String) async throws -> Bool {
    throw BackendError.networkUnavailable
  }

  func distinctLegInstrumentIds() async throws -> Set<String> {
    throw BackendError.networkUnavailable
  }

  func countNeedsReview() async throws -> Int {
    throw BackendError.networkUnavailable
  }
}

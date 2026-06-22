import Foundation
import Testing

@testable import Moolah

@Suite("TransactionStore/Load Race")
@MainActor
struct TransactionStoreLoadRaceTests {
  private let accountId = UUID()

  /// Two `load()` calls in flight at the same time (e.g. SwiftUI re-mounting
  /// `TransactionListView` during Analysis → Account navigation and firing
  /// `.task(id: baseFilter)` twice) must not cause the earlier fetch's result
  /// to be appended on top of the later one. See #372.
  @Test
  func concurrentLoadsDoNotDuplicateRows() async throws {
    let transactions = try TransactionStoreTestSupport.seedTransactions(
      count: 3, accountId: accountId)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    async let first: Void = store.load(filter: TransactionFilter(accountId: accountId))
    async let second: Void = store.load(filter: TransactionFilter(accountId: accountId))
    _ = await (first, second)

    #expect(store.transactions.count == 3)
    let ids = Set(store.transactions.map(\.transaction.id))
    #expect(ids.count == 3)
  }

  /// An empty store reports no loaded filter, so the first mount of a view
  /// always triggers its initial fetch.
  @Test
  func firstMountTriggersInitialLoad() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    #expect(!store.isLoaded(for: TransactionFilter(accountId: accountId)))
    #expect(!store.isLoaded(for: TransactionFilter()))
  }

  /// A spurious re-mount after a successful load sees `isLoaded(for:)` as
  /// `true` and skips the redundant fetch.
  @Test
  func reMountWithSameFilterSkipsReload() async throws {
    let (backend, database) = try TestBackend.create()
    let transactions = try TransactionStoreTestSupport.seedTransactions(
      count: 2, accountId: accountId)
    TestBackend.seed(transactions: transactions, in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    let filter = TransactionFilter(accountId: accountId)
    await store.load(filter: filter)

    #expect(store.isLoaded(for: filter))
  }

  /// A completed zero-result load still counts as loaded — otherwise an empty
  /// account would re-fetch on every re-mount since `transactions` stays
  /// empty.
  @Test
  func emptyResultLoadStillCountsAsLoaded() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    let filter = TransactionFilter(accountId: accountId)
    await store.load(filter: filter)

    #expect(store.transactions.isEmpty)
    #expect(store.isLoaded(for: filter))
  }

  /// Switching accounts replaces the store's load state, so `isLoaded(for:)`
  /// is `true` for the new filter and `false` for the previous one — the
  /// `.task` for the new account will actually fetch.
  @Test
  func switchingFiltersResetsLoadState() async throws {
    let otherId = UUID()
    let filterA = TransactionFilter(accountId: accountId)
    let filterB = TransactionFilter(accountId: otherId)

    let transactions =
      try TransactionStoreTestSupport.seedTransactions(count: 2, accountId: accountId)
      + TransactionStoreTestSupport.seedTransactions(count: 1, accountId: otherId)
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(transactions: transactions, in: database)
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    await store.load(filter: filterA)
    #expect(store.isLoaded(for: filterA))

    await store.load(filter: filterB)
    #expect(store.isLoaded(for: filterB))
    #expect(!store.isLoaded(for: filterA))
  }

  /// A failed fetch leaves `isLoaded(for:)` as `false` so a subsequent
  /// re-mount retries instead of silently showing the empty error state.
  @Test
  func failedLoadAllowsRetryOnRemount() async throws {
    let store = TransactionStore(
      repository: FailingTransactionRepository(),
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )

    let filter = TransactionFilter(accountId: accountId)
    await store.load(filter: filter)

    #expect(store.error != nil)
    #expect(!store.isLoaded(for: filter))
  }

  /// A `load(filter:)` cancelled mid-fetch must not leave the store reporting
  /// itself as loading or as loaded for that filter. Otherwise the new
  /// `.task` mount that triggered the cancellation (e.g. from a structural
  /// branch flip when an asynchronously-resolved positions panel appears
  /// alongside the transactions list) sees `isLoaded(for: filter) == true`
  /// and short-circuits its own load — leaving the user staring at an empty
  /// transaction list. Sibling of #412.
  @Test
  func cancelledLoadAllowsRetryOnRemount() async throws {
    let repo = FirstFetchGatedTransactionRepository()
    let store = TransactionStore(
      repository: repo,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )
    let filter = TransactionFilter(accountId: accountId)

    let task = Task { @MainActor in
      await store.load(filter: filter)
    }
    await repo.waitUntilFetchStarted()
    task.cancel()
    await repo.releaseFetch()
    await task.value

    #expect(!store.isLoading)
    #expect(!store.isLoaded(for: filter))
  }

  /// A `load(filter:)` cancelled mid-fetch must not surface
  /// `CancellationError` as a user-facing error. The InvestmentAccountView
  /// flips `initialLoadComplete` on account switch, which unmounts the
  /// embedded `TransactionListView` and cancels its in-flight load; the
  /// surrounding alert observer treats any non-nil `store.error` as
  /// presentable, so leaking the cancellation produced a spurious "Operation
  /// failed: Swift.CancellationError" dialog on every subsequent visit to an
  /// investment account.
  @Test
  func cancelledLoadDoesNotSurfaceCancellationError() async throws {
    let repo = FirstFetchGatedTransactionRepository()
    let store = TransactionStore(
      repository: repo,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument
    )
    let filter = TransactionFilter(accountId: accountId)

    let task = Task { @MainActor in
      await store.load(filter: filter)
    }
    await repo.waitUntilFetchStarted()
    task.cancel()
    await repo.releaseFetch()
    await task.value

    #expect(store.error == nil)
  }
}

/// Minimal `TransactionRepository` that suspends inside `fetch` until the
/// test releases it, giving the test a deterministic window in which to
/// cancel the surrounding `Task`. Distinct from
/// `CancellablePagingTransactionRepository`, which gates the *second* page
/// for pagination tests; this one gates the *first* fetch so we can model
/// an initial-load cancellation.
actor FirstFetchGatedTransactionRepository: TransactionRepository {
  private let fetchStarted = AsyncGate()
  private let fetchRelease = AsyncGate()

  func waitUntilFetchStarted() async {
    await fetchStarted.wait()
  }

  func releaseFetch() async {
    await fetchRelease.open()
  }

  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
    await fetchStarted.open()
    await fetchRelease.wait()
    // Mirror GRDB's `database.read` cooperative cancellation: when the
    // surrounding task has been cancelled by the time the read can proceed,
    // throw `CancellationError` rather than returning a stale page. This is
    // what the production repository does and is the shape `fetchPage`'s
    // catch block has to handle.
    try Task.checkCancellation()
    return TransactionPage(
      transactions: [],
      targetInstrument: .defaultTestInstrument,
      priorBalance: nil,
      totalCount: nil
    )
  }

  func fetchAll(filter: TransactionFilter) async throws -> [Transaction] { [] }
  nonisolated func observe(
    filter: TransactionFilter, page: Int, pageSize: Int
  ) -> AsyncStream<TransactionPage> {
    AsyncStream { $0.finish() }
  }
  nonisolated func observeAll(filter: TransactionFilter) -> AsyncStream<[Transaction]> {
    AsyncStream { $0.finish() }
  }
  nonisolated func observeErrors() -> AsyncStream<any Error> {
    AsyncStream { $0.finish() }
  }
  func create(_ transaction: Transaction) async throws -> Transaction { transaction }
  func createMany(_ transactions: [Transaction]) async throws -> [Transaction] { transactions }
  func update(_ transaction: Transaction) async throws -> Transaction { transaction }
  func delete(id: UUID) async throws {}
  func replace(deletingIds: [UUID], creating: [Transaction]) async throws -> [Transaction] {
    creating
  }
  func fetchPayeeSuggestions(
    prefix: String, excludingTransactionId: UUID?
  ) async throws -> [String] { [] }
  func legs(matchingExternalId externalId: String) async throws -> [TransactionLeg] { [] }
  func transactions(touchingExternalIds externalIds: Set<String>) async throws -> [Transaction] {
    []
  }
  func legExists(accountId: UUID, externalId: String) async throws -> Bool { false }
  func distinctLegInstrumentIds() async throws -> Set<String> { [] }
  func countNeedsReview() async throws -> Int { 0 }
}

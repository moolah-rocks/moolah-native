import Foundation
import Testing

@testable import Moolah

@Suite("TransactionStore/Load Race")
@MainActor
struct TransactionStoreLoadRaceTests {
  private let accountId = UUID()

  /// `load(filter:)` must not resolve while its own recompute has been
  /// superseded — and therefore dropped — by a concurrent subscription
  /// re-apply that has not finished recomputing yet. Otherwise `load()`
  /// returns with the pre-load empty list still showing, then the superseding
  /// recompute publishes a tick later: the intermittent `count == 0` that made
  /// `mixedLegTransactionIsAlwaysVisible` flaky under iOS scheduling (#1209
  /// follow-up). The fix makes `runImperativeReload` wait for a publish at (or
  /// past) its snapshot's generation.
  @Test
  func loadWaitsForPublishWhenImperativeRecomputeSuperseded() async throws {
    let usd = Instrument.USD
    let aud = Instrument.AUD
    // A USD leg with an AUD target forces a `convertResultBatch`, so the gate
    // fires inside the imperative reload's recompute.
    let txn = Transaction(
      date: Date(),
      legs: [TransactionLeg(accountId: accountId, instrument: usd, quantity: 10, type: .income)])
    let page = TransactionPage(
      transactions: [txn], targetInstrument: aud, priorBalance: nil, totalCount: 1)

    let conversion = GatingConversionService()
    let store = TransactionStore(
      repository: FixedPageTransactionRepository(page: page),
      conversionService: conversion,
      targetInstrument: aud)

    // Gate the imperative reload's recompute mid-conversion.
    conversion.armGate()
    let loadTask = Task<Int, Never> { @MainActor in
      await store.load(filter: TransactionFilter(accountId: accountId))
      return store.transactions.count
    }
    await conversion.waitUntilGateReached()

    // A concurrent subscription re-apply of the same data lands while the
    // imperative recompute is suspended, bumping the snapshot generation so the
    // imperative recompute is stale and will drop when it resumes.
    store.bumpSnapshotGeneration()

    // Release the imperative recompute. It drops without publishing. Drain the
    // main actor so that, WITHOUT the fix, `load()` returns here with the list
    // still empty (captured as `0`).
    conversion.releaseGate()
    for _ in 0..<20 { await Task.yield() }

    // The superseding recompute finally publishes its rows; the fix keeps
    // `load()` parked until exactly this point.
    await store.applySnapshot(page, observedCount: 1, fetchMs: 0)

    #expect(await loadTask.value == 1)
    store.stopObserving()
  }

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

/// A `TransactionRepository` that returns a fixed page from every `fetch`, and
/// whose `observe` stays open without ever emitting. This lets a test drive the
/// imperative reload's snapshot deterministically while suppressing the real
/// subscription's re-apply (which the test models explicitly with
/// `applySnapshot`).
private final class FixedPageTransactionRepository: TransactionRepository, Sendable {
  private let page: TransactionPage

  init(page: TransactionPage) { self.page = page }

  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
    self.page
  }

  func fetchAll(filter: TransactionFilter) async throws -> [Transaction] { page.transactions }
  nonisolated func observe(
    filter: TransactionFilter, page: Int, pageSize: Int
  ) -> AsyncStream<TransactionPage> {
    AsyncStream { _ in }
  }
  nonisolated func observeAll(filter: TransactionFilter) -> AsyncStream<[Transaction]> {
    AsyncStream { _ in }
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

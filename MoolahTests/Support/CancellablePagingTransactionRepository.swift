import Foundation

@testable import Moolah

/// Test double for `TransactionRepository` that exercises pagination
/// cancellation. Returns a single full page on the first `fetch` call and
/// blocks on the second call until `releaseSecondFetch()` is invoked — giving
/// tests a deterministic window in which to cancel the enclosing `Task`.
actor CancellablePagingTransactionRepository: TransactionRepository {
  private let pageSize: Int
  private let firstFetchStarted = AsyncGate()
  private let secondFetchRelease = AsyncGate()
  private var fetchCount = 0

  init(pageSize: Int) {
    self.pageSize = pageSize
  }

  func waitForFirstFetch() async {
    await firstFetchStarted.wait()
  }

  func releaseSecondFetch() async {
    await secondFetchRelease.open()
  }

  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
    fetchCount += 1
    let currentFetch = fetchCount

    if currentFetch == 1 {
      await firstFetchStarted.open()
      // Return a full page (pageSize transactions) so the caller loops for more.
      let txns = (0..<self.pageSize).map { _ in
        Transaction(id: UUID(), date: Date(), legs: [])
      }
      return TransactionPage(
        transactions: txns,
        targetInstrument: .defaultTestInstrument,
        priorBalance: nil,
        totalCount: nil
      )
    }

    // Block on the second page until the test releases us, giving the test a
    // window to cancel the task.
    await secondFetchRelease.wait()
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

/// A simple one-shot gate that suspends waiters until `open()` is called.
/// Once opened, subsequent `wait()` calls return immediately.
actor AsyncGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func open() {
    guard !isOpen else { return }
    isOpen = true
    let pending = waiters
    waiters.removeAll()
    for waiter in pending {
      waiter.resume()
    }
  }

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { continuation in
      waiters.append(continuation)
    }
  }
}

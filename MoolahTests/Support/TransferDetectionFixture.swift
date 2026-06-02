import Foundation

@testable import Moolah

/// Shared fixture and repository test doubles for the
/// `TransferDetectionCoordinator` suites.
enum TransferDetectionFixture {
  static let accountA = UUID()
  static let accountB = UUID()

  /// A single-leg cash transaction on `account` for `amount`
  /// (negative = outgoing).
  static func cashTx(
    id: UUID = UUID(),
    account: UUID,
    amount: Decimal,
    type: TransactionType,
    on date: Date
  ) -> Transaction {
    Transaction(
      id: id,
      date: date,
      legs: [
        TransactionLeg(
          accountId: account,
          instrument: .defaultTestInstrument,
          quantity: amount,
          type: type)
      ])
  }

  @MainActor
  static func makeCoordinator(
    backend: CloudKitBackend,
    clock: @escaping @Sendable () -> Date = { Date() }
  ) -> TransferDetectionCoordinator {
    TransferDetectionCoordinator(
      transactions: backend.transactions,
      suggestions: backend.transferSuggestions,
      clock: clock)
  }
}

/// Forwards every `TransactionRepository` call to a wrapped repository
/// except `replace`, which throws a sentinel error — used to assert the
/// merge stays atomic (neither source deleted) when the atomic write
/// fails.
struct ReplaceFailingTransactionRepository: TransactionRepository {
  let wrapped: any TransactionRepository

  init(wrapping wrapped: any TransactionRepository) {
    self.wrapped = wrapped
  }

  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
    try await wrapped.fetch(filter: filter, page: page, pageSize: pageSize)
  }
  func fetchAll(filter: TransactionFilter) async throws -> [Transaction] {
    try await wrapped.fetchAll(filter: filter)
  }
  func observe(
    filter: TransactionFilter, page: Int, pageSize: Int
  ) -> AsyncStream<TransactionPage> {
    wrapped.observe(filter: filter, page: page, pageSize: pageSize)
  }
  func observeAll(filter: TransactionFilter) -> AsyncStream<[Transaction]> {
    wrapped.observeAll(filter: filter)
  }
  func observeErrors() -> AsyncStream<any Error> { wrapped.observeErrors() }
  func create(_ transaction: Transaction) async throws -> Transaction {
    try await wrapped.create(transaction)
  }
  func createMany(_ transactions: [Transaction]) async throws -> [Transaction] {
    try await wrapped.createMany(transactions)
  }
  func update(_ transaction: Transaction) async throws -> Transaction {
    try await wrapped.update(transaction)
  }
  func delete(id: UUID) async throws { try await wrapped.delete(id: id) }
  func replace(deletingIds: [UUID], creating: [Transaction]) async throws -> [Transaction] {
    throw BackendError.networkUnavailable
  }
  func fetchPayeeSuggestions(
    prefix: String, excludingTransactionId: UUID?
  ) async throws -> [String] {
    try await wrapped.fetchPayeeSuggestions(
      prefix: prefix, excludingTransactionId: excludingTransactionId)
  }
  func legs(matchingExternalId externalId: String) async throws -> [TransactionLeg] {
    try await wrapped.legs(matchingExternalId: externalId)
  }
  func transactions(touchingExternalIds externalIds: Set<String>) async throws -> [Transaction] {
    try await wrapped.transactions(touchingExternalIds: externalIds)
  }
  func legExists(accountId: UUID, externalId: String) async throws -> Bool {
    try await wrapped.legExists(accountId: accountId, externalId: externalId)
  }
  func distinctLegInstrumentIds() async throws -> Set<String> {
    try await wrapped.distinctLegInstrumentIds()
  }

  func countNeedsReview() async throws -> Int {
    try await wrapped.countNeedsReview()
  }
}

/// Forwards every call to a wrapped repository, but suspends inside
/// `replace` until the test opens a gate — giving the re-entrancy test
/// a deterministic window where one mutation is in flight.
actor GatedReplaceTransactionRepository: TransactionRepository {
  private let wrapped: any TransactionRepository
  private let replaceStarted = AsyncGate()
  private let replaceRelease = AsyncGate()

  init(wrapping wrapped: any TransactionRepository) {
    self.wrapped = wrapped
  }

  func waitUntilReplaceStarted() async { await replaceStarted.wait() }
  func releaseReplace() async { await replaceRelease.open() }

  nonisolated func fetch(
    filter: TransactionFilter, page: Int, pageSize: Int
  ) async throws -> TransactionPage {
    try await wrapped.fetch(filter: filter, page: page, pageSize: pageSize)
  }
  nonisolated func fetchAll(filter: TransactionFilter) async throws -> [Transaction] {
    try await wrapped.fetchAll(filter: filter)
  }
  nonisolated func observe(
    filter: TransactionFilter, page: Int, pageSize: Int
  ) -> AsyncStream<TransactionPage> {
    wrapped.observe(filter: filter, page: page, pageSize: pageSize)
  }
  nonisolated func observeAll(filter: TransactionFilter) -> AsyncStream<[Transaction]> {
    wrapped.observeAll(filter: filter)
  }
  nonisolated func observeErrors() -> AsyncStream<any Error> {
    wrapped.observeErrors()
  }
  nonisolated func create(_ transaction: Transaction) async throws -> Transaction {
    try await wrapped.create(transaction)
  }
  nonisolated func createMany(_ transactions: [Transaction]) async throws -> [Transaction] {
    try await wrapped.createMany(transactions)
  }
  nonisolated func update(_ transaction: Transaction) async throws -> Transaction {
    try await wrapped.update(transaction)
  }
  nonisolated func delete(id: UUID) async throws { try await wrapped.delete(id: id) }
  func replace(deletingIds: [UUID], creating: [Transaction]) async throws -> [Transaction] {
    await replaceStarted.open()
    await replaceRelease.wait()
    try Task.checkCancellation()
    return try await wrapped.replace(deletingIds: deletingIds, creating: creating)
  }
  nonisolated func fetchPayeeSuggestions(
    prefix: String, excludingTransactionId: UUID?
  ) async throws -> [String] {
    try await wrapped.fetchPayeeSuggestions(
      prefix: prefix, excludingTransactionId: excludingTransactionId)
  }
  nonisolated func legs(matchingExternalId externalId: String) async throws -> [TransactionLeg] {
    try await wrapped.legs(matchingExternalId: externalId)
  }
  nonisolated func transactions(
    touchingExternalIds externalIds: Set<String>
  ) async throws -> [Transaction] {
    try await wrapped.transactions(touchingExternalIds: externalIds)
  }
  nonisolated func legExists(accountId: UUID, externalId: String) async throws -> Bool {
    try await wrapped.legExists(accountId: accountId, externalId: externalId)
  }
  nonisolated func distinctLegInstrumentIds() async throws -> Set<String> {
    try await wrapped.distinctLegInstrumentIds()
  }

  nonisolated func countNeedsReview() async throws -> Int {
    try await wrapped.countNeedsReview()
  }
}

/// Forwards every call to a wrapped repository, but suspends inside
/// `fetchAll` until the test opens a gate — giving the re-entrancy test
/// a deterministic window where a detection pass is in flight.
actor GatedFetchAllTransactionRepository: TransactionRepository {
  private let wrapped: any TransactionRepository
  private let fetchAllStarted = AsyncGate()
  private let fetchAllRelease = AsyncGate()

  init(wrapping wrapped: any TransactionRepository) {
    self.wrapped = wrapped
  }

  func waitUntilFetchAllStarted() async { await fetchAllStarted.wait() }
  func releaseFetchAll() async { await fetchAllRelease.open() }

  nonisolated func fetch(
    filter: TransactionFilter, page: Int, pageSize: Int
  ) async throws -> TransactionPage {
    try await wrapped.fetch(filter: filter, page: page, pageSize: pageSize)
  }
  func fetchAll(filter: TransactionFilter) async throws -> [Transaction] {
    await fetchAllStarted.open()
    await fetchAllRelease.wait()
    try Task.checkCancellation()
    return try await wrapped.fetchAll(filter: filter)
  }
  nonisolated func observe(
    filter: TransactionFilter, page: Int, pageSize: Int
  ) -> AsyncStream<TransactionPage> {
    wrapped.observe(filter: filter, page: page, pageSize: pageSize)
  }
  nonisolated func observeAll(filter: TransactionFilter) -> AsyncStream<[Transaction]> {
    wrapped.observeAll(filter: filter)
  }
  nonisolated func observeErrors() -> AsyncStream<any Error> {
    wrapped.observeErrors()
  }
  nonisolated func create(_ transaction: Transaction) async throws -> Transaction {
    try await wrapped.create(transaction)
  }
  nonisolated func createMany(_ transactions: [Transaction]) async throws -> [Transaction] {
    try await wrapped.createMany(transactions)
  }
  nonisolated func update(_ transaction: Transaction) async throws -> Transaction {
    try await wrapped.update(transaction)
  }
  nonisolated func delete(id: UUID) async throws { try await wrapped.delete(id: id) }
  nonisolated func replace(
    deletingIds: [UUID], creating: [Transaction]
  ) async throws -> [Transaction] {
    try await wrapped.replace(deletingIds: deletingIds, creating: creating)
  }
  nonisolated func fetchPayeeSuggestions(
    prefix: String, excludingTransactionId: UUID?
  ) async throws -> [String] {
    try await wrapped.fetchPayeeSuggestions(
      prefix: prefix, excludingTransactionId: excludingTransactionId)
  }
  nonisolated func legs(matchingExternalId externalId: String) async throws -> [TransactionLeg] {
    try await wrapped.legs(matchingExternalId: externalId)
  }
  nonisolated func transactions(
    touchingExternalIds externalIds: Set<String>
  ) async throws -> [Transaction] {
    try await wrapped.transactions(touchingExternalIds: externalIds)
  }
  nonisolated func legExists(accountId: UUID, externalId: String) async throws -> Bool {
    try await wrapped.legExists(accountId: accountId, externalId: externalId)
  }
  nonisolated func distinctLegInstrumentIds() async throws -> Set<String> {
    try await wrapped.distinctLegInstrumentIds()
  }

  nonisolated func countNeedsReview() async throws -> Int {
    try await wrapped.countNeedsReview()
  }
}

// MoolahTests/Shared/CryptoImport/RecordingTransactionRepository.swift
import Foundation

@testable import Moolah

/// Recording wrapper around a `TransactionRepository`. Forwards every
/// call to the wrapped repository while remembering which `delete(id:)`
/// calls a unit-under-test made — used by `CrossDeviceLegDeduperTests`
/// to verify the repository-routed delete invariant. Forwards every
/// other method directly so the wrapped `CloudKitBackend` does the
/// actual persistence work.
///
/// `actor` so `deletedIds` can be observed from `@MainActor` tests
/// without tripping Sendable diagnostics.
actor RecordingTransactionRepository: TransactionRepository {
  private let wrapped: any TransactionRepository
  private(set) var deletedIds: [UUID] = []

  init(wrapping wrapped: any TransactionRepository) {
    self.wrapped = wrapped
  }

  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
    try await wrapped.fetch(filter: filter, page: page, pageSize: pageSize)
  }

  func fetchAll(filter: TransactionFilter) async throws -> [Transaction] {
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

  func create(_ transaction: Transaction) async throws -> Transaction {
    try await wrapped.create(transaction)
  }

  func createMany(_ transactions: [Transaction]) async throws -> [Transaction] {
    try await wrapped.createMany(transactions)
  }

  func update(_ transaction: Transaction) async throws -> Transaction {
    try await wrapped.update(transaction)
  }

  func delete(id: UUID) async throws {
    deletedIds.append(id)
    try await wrapped.delete(id: id)
  }

  func replace(deletingIds: [UUID], creating: [Transaction]) async throws -> [Transaction] {
    deletedIds.append(contentsOf: deletingIds)
    return try await wrapped.replace(deletingIds: deletingIds, creating: creating)
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

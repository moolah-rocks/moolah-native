import Foundation

// Transaction-fetch convenience for `InvestmentStore`.
extension InvestmentStore {
  // MARK: - Convenience fetch

  /// Single-account convenience that delegates to
  /// `MultiInstrumentPositionsAssembler.fetchTransactions(repository:accountIds:)`.
  /// Used by `refreshPositionTrackedPerformance` in
  /// `InvestmentStore+Positions.swift`, which supplies a single `UUID`.
  func fetchAllTransactions(
    repository: TransactionRepository,
    accountId: UUID
  ) async throws -> [Transaction] {
    let assembler = MultiInstrumentPositionsAssembler(conversionService: conversionService)
    return try await assembler.fetchTransactions(
      repository: repository,
      accountIds: [accountId])
  }
}

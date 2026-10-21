import Foundation

/// Narrow background-read boundary. Implementations must push limits into storage.
protocol ReadQueryRepository: Sendable {
  func using(defaultInstrument: Instrument) -> any ReadQueryRepository
  func accounts(
    includeHidden: Bool,
    page: ReadPageRequest
  ) async throws -> ReadPage<ReadAccountDTO>
  func categories(page: ReadPageRequest) async throws -> ReadPage<ReadCategoryDTO>
  func earmarks(page: ReadPageRequest) async throws -> ReadPage<ReadEarmarkDTO>
  /// Account/category constraints must match the same leg; returned transactions retain all legs.
  func transactions(
    search: ReadTransactionSearch,
    page: ReadPageRequest,
    includeNotes: Bool
  ) async throws -> ReadPage<ReadTransactionDTO>
  func transaction(
    id: UUID,
    includeNotes: Bool
  ) async throws -> ReadPage<ReadTransactionDTO>
  func balances(accountIDs: Set<UUID>) async throws -> ReadPage<ReadBalanceDTO>
  /// Canonical inputs for valuation; implementations preserve the same bounded snapshot contract.
  func balanceInputs(accountIDs: Set<UUID>) async throws -> ReadPage<ReadBalanceInput>
  /// Reports income/expense semantics and current positions read within one database snapshot.
  func summaryInputs(range: ReadDateRange) async throws -> ReadSummarySnapshot
}

extension ReadQueryRepository {
  func using(defaultInstrument: Instrument) -> any ReadQueryRepository { self }

  func transactions(
    search: ReadTransactionSearch,
    page: ReadPageRequest
  ) async throws
    -> ReadPage<ReadTransactionDTO>
  {
    try await transactions(search: search, page: page, includeNotes: false)
  }

  func transaction(id: UUID) async throws -> ReadPage<ReadTransactionDTO> {
    try await transaction(id: id, includeNotes: false)
  }
}

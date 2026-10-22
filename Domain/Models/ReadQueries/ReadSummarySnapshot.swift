import Foundation

/// Internal calculation input retains canonical instruments; it is never serialized directly.
struct ReadBalanceInput: Sendable {
  let accountID: UUID
  let positions: [InstrumentAmount]
  let accountName: String?

}

/// A posted report leg from one bounded profile-database snapshot.
struct ReadSummaryFlow: Sendable {
  let date: Date
  let categoryID: UUID?
  let type: TransactionType
  let amount: InstrumentAmount
}

/// Requested flows and optional current positions share one database snapshot, excluding scheduled entries.
struct ReadSummarySnapshot: Sendable {
  let flows: [ReadSummaryFlow]
  let netWorth: ReadNetWorthInput
  let categories: [ReadCategoryDTO]
  let timeZone: TimeZone
  let revision: String
  let queriedAt: Date
}

/// Omission is distinct from an explicitly requested empty portfolio.
enum ReadNetWorthInput: Sendable {
  case omitted
  case requested([ReadBalanceInput])
}

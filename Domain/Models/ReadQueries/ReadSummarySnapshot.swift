import Foundation

/// Internal calculation input retains canonical instruments; it is never serialized directly.
struct ReadBalanceInput: Sendable {
  let accountID: UUID
  let positions: [InstrumentAmount]
}

/// A posted report leg from one bounded profile-database snapshot.
struct ReadSummaryFlow: Sendable {
  let date: Date
  let categoryID: UUID?
  let type: TransactionType
  let amount: InstrumentAmount
}

/// Flows and current posted positions share one database snapshot, excluding scheduled entries.
struct ReadSummarySnapshot: Sendable {
  let flows: [ReadSummaryFlow]
  let balances: [ReadBalanceInput]
  let revision: String
  let queriedAt: Date
}

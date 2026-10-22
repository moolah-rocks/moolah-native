import Foundation

/// A daily price bucket also retains the independent local month used for report grouping.
struct ReadSummaryBucket: Sendable {
  let date: Date
  let month: String?
  let categoryID: UUID?
  let type: TransactionType
  let amount: InstrumentAmount
}

import Foundation

/// General transaction-merge validation failure. Distinct from
/// `TransferMergeError` / `ManualMergeError`, which govern the
/// two-leg transfer merge. Cases carry no payload, so `Sendable`
/// is trivially satisfied for crossing actor boundaries.
enum TransactionMergeError: Error, Equatable, Sendable {
  case tooFewTransactions  // fewer than two transactions supplied
  case differentDays  // not all on the same calendar day
  case differentPayees  // payees are not all equal
  case containsScheduled  // a scheduled / recurring transaction was included
}

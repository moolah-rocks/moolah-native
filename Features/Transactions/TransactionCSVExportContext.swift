import Foundation

/// Immutable snapshot of the transaction-list projection used for a CSV export.
/// The store supplies every repository match; the builder applies the list-only
/// search and spam-visibility rules to that complete set.
struct TransactionCSVExportContext: Sendable {
  let filter: TransactionFilter
  let searchText: String
  let includesSpam: Bool
  let spamInstruments: Set<Instrument>
  /// User timezone captured when export begins so date-only values match the
  /// visible transaction list throughout the asynchronous snapshot.
  let timeZone: TimeZone
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
}

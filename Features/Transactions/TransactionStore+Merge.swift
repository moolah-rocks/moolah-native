import Foundation

// General N-way transaction merge for the transaction list. Distinct
// from the transfer-merge pass-throughs in
// `TransactionStore+TransferDetection.swift`: a general merge has no
// `TransferSuggestion` to delete, so it does not route through
// `TransferDetectionCoordinator`. It builds the combined transaction
// with the shared `TransactionMergeBuilder` and swaps sources → merged
// in one atomic `replace`, surfacing any failure on the store's own
// `error` channel (same shape as the `delete` / `update` mutations).
extension TransactionStore {
  /// Combines two or more transactions (same day, same payee, none
  /// scheduled) into one whose legs are the union of the sources'
  /// legs, deleting the sources and creating the merged transaction in
  /// one atomic write. On an invalid selection the builder throws a
  /// `TransactionMergeError`, which is surfaced on `error` and leaves
  /// the store unmutated. The list gate (`Transaction.canMerge`) means
  /// the throw path is defensive in normal use.
  func mergeTransactions(_ transactions: [Transaction]) async {
    setError(nil)
    do {
      let merged = try TransactionMergeBuilder().merged(transactions)
      _ = try await repository.replace(
        deletingIds: transactions.map(\.id), creating: [merged])
      logger.debug("Merged \(transactions.count) transactions into \(merged.id)")
    } catch {
      logger.error("Failed to merge transactions: \(error.localizedDescription)")
      setError(error)
    }
  }
}

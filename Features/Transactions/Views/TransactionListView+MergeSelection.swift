import Foundation

// Selection-shape gates for the two merge commands the transaction list
// exposes. Both resolve the `List`'s multi-selection against the loaded
// projection and apply the cheap model-level predicate; the stores /
// coordinators re-validate authoritatively. Kept in their own file so
// `TransactionListView+List.swift` stays within the file-length budget
// and the merge gates read as one cohesive unit.
extension TransactionListView {
  /// The two transactions the user has multi-selected for a manual
  /// (transfer) merge, resolved from the loaded projection, or `nil`
  /// when the selection is not exactly a valid candidate pair. Shared
  /// by the list toolbar and the row context menu so the gate logic is
  /// not duplicated; the menu-bar command applies the same
  /// `Transaction.canManualMerge` predicate over the focused value.
  var manualMergePair: (Transaction, Transaction)? {
    guard multiSelectedTransactionIDs.count == 2 else { return nil }
    let selected = resolvedSelection()
    guard selected.count == 2 else { return nil }
    guard Transaction.canManualMerge(selected[0], with: selected[1]) else { return nil }
    return (selected[0], selected[1])
  }

  /// The two-or-more transactions the user has multi-selected for a
  /// general merge, or an empty array when the selection is not a valid
  /// merge candidate (fewer than two, mixed day/payee, or scheduled).
  /// Shared by the row context menu and the menu-bar focused action so
  /// the gate is not duplicated; `Transaction.canMerge` is the single
  /// predicate. Empty (rather than optional) so callers gate on
  /// `isEmpty`.
  var mergeSelection: [Transaction] {
    guard multiSelectedTransactionIDs.count >= 2 else { return [] }
    let selected = resolvedSelection()
    guard selected.count == multiSelectedTransactionIDs.count else { return [] }
    guard Transaction.canMerge(selected) else { return [] }
    return selected
  }

  /// The loaded `Transaction` objects for the current multi-selection,
  /// in projection order. Shared by both merge gates so the
  /// selection-to-transaction lookup is written once.
  private func resolvedSelection() -> [Transaction] {
    transactionStore.transactions
      .map(\.transaction)
      .filter { multiSelectedTransactionIDs.contains($0.id) }
  }
}

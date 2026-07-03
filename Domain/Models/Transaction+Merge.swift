import Foundation

extension Transaction {
  /// `true` iff `transactions` form a valid general-merge selection:
  /// two or more, all on the same calendar day, all with the same
  /// payee, and none scheduled/recurring. This is the cheap
  /// menu-enable gate shared by the menu bar, context menu, and the
  /// focused action; `TransactionMergeBuilder.merged(_:)` re-validates
  /// authoritatively and throws `TransactionMergeError` for anything
  /// this gate lets through. Distinct from `canManualMerge`, which
  /// gates the two-leg transfer merge.
  static func canMerge(_ transactions: [Transaction]) -> Bool {
    guard transactions.count >= 2 else { return false }
    let first = transactions[0]
    return transactions.allSatisfy { $0.payee == first.payee }
      && transactions.allSatisfy { $0.date.isSameDay(as: first.date) }
      && transactions.allSatisfy { $0.recurPeriod == nil }
  }
}

import Foundation

extension UITestIdentifiers {
  // MARK: - TransactionMerge

  /// Identifiers for the general "Merge Transactions" command (distinct
  /// from `TransferDetection.merge`, which is the transfer merge).
  public enum TransactionMerge {
    /// The "Merge Transactions" context-menu item shown on a row that is
    /// part of a valid multi-selection. `id` is that row's UUID,
    /// lowercased.
    public static func merge(_ id: UUID) -> String {
      "transactionmerge.merge.\(id.uuidString.lowercased())"
    }
  }
}

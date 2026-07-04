import Foundation

extension UITestIdentifiers {
  // MARK: - TransactionList

  public enum TransactionList {
    /// Root container of the transaction list (centre column). Used as a
    /// stable post-condition sentinel after sidebar selection — the row
    /// for any specific transaction is data-dependent, but the container
    /// renders for every account.
    public static let container = "transactionlist.container"

    /// Centre-column row for a specific transaction. `id` is the
    /// transaction's UUID, lowercased.
    public static func transaction(_ id: UUID) -> String {
      "transactionlist.transaction.\(id.uuidString.lowercased())"
    }

    /// iOS-only toolbar button that toggles spam-transaction visibility.
    /// Pinned so a UI test can drive the spam toggle without depending on
    /// the rendered label text (which flips between states).
    public static let spamToggleButton = "transactionlist.toolbar.spamToggle"

    /// Toolbar button that opens the transaction filter sheet. Drivers
    /// click it to present `TransactionFilterView`.
    public static let filterButton = "transactionlist.toolbar.filter"
  }
}

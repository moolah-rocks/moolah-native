import Foundation

extension UITestIdentifiers {
  // MARK: - TransactionFilter

  /// Identifiers for the transaction filter sheet (`TransactionFilterView`).
  public enum TransactionFilter {
    /// The account multi-select trigger (macOS popover / iOS NavigationLink).
    public static let accountPicker = "transactionFilter.accountPicker"
    /// The "Filter by Date" toggle.
    public static let dateToggle = "transactionFilter.dateToggle"
    /// The Apply button in the sheet toolbar.
    public static let apply = "transactionFilter.apply"

    /// A single account row inside the account multi-select.
    public static func account(_ id: UUID) -> String {
      "transactionFilter.account.\(id.uuidString.lowercased())"
    }
  }
}

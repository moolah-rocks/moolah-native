import Foundation

extension UITestIdentifiers {
  /// Identifier namespace for `PositionsChartTransactionsSplit`, the
  /// unified account-detail container (crypto / exchange / standard /
  /// group accounts).
  public enum AccountDetail {
    /// The positions surface — iOS `Positions` tab / macOS pinned top
    /// pane. Absent for fiat-only accounts (no non-host holdings).
    public static let positionsPane = "accountDetail.positionsPane"

    /// The chart + performance surface — iOS `Chart` tab / macOS Chart
    /// companion in the bottom toggle pane.
    public static let chartPane = "accountDetail.chartPane"

    /// The segmented tab picker (iOS full tab set / macOS bottom-pane
    /// `[Transactions | Chart]` toggle).
    public static let tabPicker = "accountDetail.tabPicker"

    /// Visible label of the "Transactions" segment in the bottom-pane toggle.
    public static let transactionsSegmentLabel = "Transactions"
    /// Visible label of the "Chart" segment in the bottom-pane toggle.
    public static let chartSegmentLabel = "Chart"
  }
}

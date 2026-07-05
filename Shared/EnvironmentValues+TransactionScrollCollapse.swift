import SwiftUI

extension EnvironmentValues {
  /// Injected by the macOS `PositionsChartTransactionsSplit` when it hosts
  /// the transaction list in its bottom toggle and wants its header to
  /// collapse on scroll. `nil` everywhere else (iOS, standalone transaction
  /// lists) — the scroll observer becomes a no-op.
  @Entry var transactionScrollCollapse: TransactionScrollCollapse?
}

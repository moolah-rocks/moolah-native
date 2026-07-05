import Foundation

/// The three surfaces the unified account-detail screen can present. On
/// iOS these are segmented tabs; on macOS `.positions` is the pinned top
/// pane and `.transactions` / `.chart` are the resizable bottom pane's
/// toggle.
enum AccountDetailTab: Hashable {
  case transactions
  case positions
  case chart
}

/// Pure, data-driven layout decisions for `PositionsChartTransactionsSplit`.
/// Kept free of any view or actor state so the tab / pane rules are
/// unit-testable in isolation and callable from both `@MainActor` views
/// and synchronous tests.
enum AccountDetailLayout {
  /// iOS segmented-tab order. Transactions is always first (and the
  /// default selection); Chart is always last; Positions is inserted
  /// between them only when the account has non-host-currency holdings.
  static func iOSTabs(hasPositions: Bool) -> [AccountDetailTab] {
    hasPositions ? [.transactions, .positions, .chart] : [.transactions, .chart]
  }

  /// The macOS bottom-pane toggle is always `[Transactions | Chart]`,
  /// independent of holdings — the positions table, when present, is the
  /// pinned top pane rather than a bottom-pane tab.
  static let macBottomTabs: [AccountDetailTab] = [.transactions, .chart]

  /// Whether the macOS layout pins a positions table above the resizable
  /// `[Transactions | Chart]` pane. `false` → a single full-height pane
  /// carrying just the toggle.
  static func macShowsPinnedPositions(hasPositions: Bool) -> Bool { hasPositions }

  /// Whether the account has holdings worth surfacing in a positions
  /// table — at least one non-zero position in an instrument other than
  /// the host currency. Drives Positions-tab / pinned-pane presence only;
  /// the chart and transactions render unconditionally.
  ///
  /// Once the valuator has produced a `positionsInput` it is
  /// authoritative — its `shouldHide` has already dropped `.knownZero`
  /// (`.spam` / `.unpriced`) rows, so it agrees with what the positions
  /// table will actually render. Pre-valuation, fall back to a raw
  /// heuristic so the Positions tab can render with a spinner.
  static func hasNonHostHoldings(
    rawPositions: [Position],
    hostCurrency: Instrument,
    positionsInput: PositionsViewInput?
  ) -> Bool {
    if let positionsInput {
      return !positionsInput.shouldHide
    }
    guard !rawPositions.isEmpty else { return false }
    let nonZeroInstruments = Set(
      rawPositions.lazy.filter { $0.quantity != 0 }.map(\.instrument))
    return nonZeroInstruments != [hostCurrency]
  }
}

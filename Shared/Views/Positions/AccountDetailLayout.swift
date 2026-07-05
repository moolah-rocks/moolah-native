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

  /// Whether the host renders its full surface (performance tiles + a
  /// positions pane) regardless of current holdings. Investment
  /// `.calculatedFromTrades` hosts pass `alwaysShowsFullSurface: true` so a
  /// fully-sold account still shows its performance / chart / positions;
  /// every other host falls through to `base` — the per-element gate that
  /// answers "does the account actually hold something worth surfacing".
  static func showsFullSurface(
    alwaysShowsFullSurface: Bool, otherwiseShows base: Bool
  ) -> Bool {
    alwaysShowsFullSurface || base
  }

  /// Whether the Chart pane shows the `AccountPerformanceTiles` strip
  /// (value / P&L / return) rather than the plain total-only
  /// `PositionsHeader`. `true` iff the account holds at least one non-zero
  /// position in an instrument other than the host currency — i.e. it has
  /// real invested / P&L data (crypto, exchange, mixed group). Fiat-only
  /// accounts fall back to the header.
  ///
  /// Reads the *valued* rows (post-valuation), so `.knownZero` / `.spam`
  /// crypto the valuator already dropped can't keep the tiles alive — this
  /// keeps the strip's presence aligned with the assembled input's
  /// `shouldHide`, hence with the pinned Positions pane: tiles and pane
  /// appear together.
  static func showsPerformanceTiles(
    valuedRows: [ValuedPosition], hostCurrency: Instrument
  ) -> Bool {
    valuedRows.contains { $0.quantity != 0 && $0.instrument != hostCurrency }
  }

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

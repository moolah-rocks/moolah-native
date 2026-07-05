// Shared/Views/Positions/AccountPerformanceTiles.swift
import SwiftUI

/// Three-tile horizontal strip rendering account-level lifetime numbers
/// from an `AccountPerformance`: Current Value, Profit / Loss (with %),
/// and Annualised Return (with "since [first-flow-date]" subtitle).
///
/// Used for both position-tracked accounts (performance supplied via
/// `PositionsViewInput.performance`) and manual-valuation accounts. Each
/// tile shows "—" / "Unavailable" rather than a partial sum when its
/// source field is `nil` — see Rule 11 in
/// `guides/INSTRUMENT_CONVERSION_GUIDE.md`.
struct AccountPerformanceTiles: View {
  let title: String
  let performance: AccountPerformance

  var body: some View {
    VStack(spacing: 8) {
      Text(title)
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
      HStack(spacing: 0) {
        currentValueTile
        Divider().frame(height: tileDividerHeight)
        profitLossTile
        Divider().frame(height: tileDividerHeight)
        annualisedReturnTile
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 12)
    .dynamicTypeSize(...DynamicTypeSize.accessibility2)
  }

  // MARK: - Tiles

  @ViewBuilder private var currentValueTile: some View {
    Tile(label: "Current Value") {
      if let value = performance.currentValue {
        Text(value.formatted)
          .font(.title3)
          .monospacedDigit()
      } else {
        Text("Unavailable")
          .font(.title3)
          .foregroundStyle(.secondary)
      }
    } subtitle: {
      investedSubtitleView
    }
    .accessibilityLabel(
      AccountPerformanceTileLabels.currentValueAccessibilityLabel(performance)
    )
  }

  @ViewBuilder private var investedSubtitleView: some View {
    if let text = AccountPerformanceTileLabels.investedSubtitleText(performance) {
      if performance.totalContributions != nil {
        Text(text)
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      } else {
        // "Invested —" form: no number to monospace; tertiary
        // colour matches the P/L tile's `—` styling.
        Text(text)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
  }

  @ViewBuilder private var profitLossTile: some View {
    Tile(label: "Profit / Loss") {
      if let profitLoss = performance.profitLoss {
        Text(profitLoss.signedFormatted)
          .font(.title3)
          .monospacedDigit()
          .foregroundStyle(plColor)
      } else {
        Text("—")
          .font(.title3)
          .foregroundStyle(.tertiary)
      }
    } subtitle: {
      if performance.profitLoss != nil, let text = profitLossPercentText {
        Text(text)
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(plColor)
      }
    }
    .accessibilityLabel(profitLossAccessibilityLabel)
  }

  @ViewBuilder private var annualisedReturnTile: some View {
    let tile = Tile(label: "Annualised Return") {
      if let rate = performance.annualisedReturn {
        Text(formattedPaPercent(rate))
          .font(.title3)
          .monospacedDigit()
          .foregroundStyle(paColor(rate))
      } else {
        Text("—")
          .font(.title3)
          .foregroundStyle(.tertiary)
          .help(annualisedReturnUnavailableTooltip)
      }
    } subtitle: {
      if let text = sinceText {
        Text(text)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .accessibilityLabel(annualisedReturnAccessibilityLabel)
    // The `Tile` uses `.accessibilityElement(children: .combine)`, which
    // creates an opaque node with its own XCUI identity — unlike a plain
    // `Text`, which inherits the nearest ancestor identifier instead — so
    // this identifier attaches to that leaf. The outer `chartPane` wrapper
    // uses `.accessibilityElement(children: .contain)` to stop any ancestor
    // identifier from propagating into this subtree.
    .accessibilityIdentifier(UITestIdentifiers.AccountDetail.performanceTiles)

    if performance.annualisedReturn == nil {
      tile.accessibilityHint(annualisedReturnUnavailableTooltip)
    } else {
      tile
    }
  }

  // MARK: - Computed strings / colours

  private var profitLossPercentText: String? {
    performance.profitLossPercent.map {
      GainLossPercentDisplay.formatted($0 * 100)
    }
  }

  /// Re-used across renders. `DateFormatter` allocation is expensive
  /// and SwiftUI views can re-render on every parent state change.
  private static let flowDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.setLocalizedDateFormatFromTemplate("MMMyyyy")
    return formatter
  }()

  private var sinceText: String? {
    guard let date = performance.firstFlowDate else { return nil }
    return "since \(Self.flowDateFormatter.string(from: date))"
  }

  /// `+8.3% p.a.` / `−4.0% p.a.` / `0.0% p.a.`. Uses the shared
  /// `GainLossPercentDisplay.formatted` so the percentage portion
  /// matches `PositionsTable.gainCell` and `PositionRow.trailingColumn`.
  private func formattedPaPercent(_ rate: Decimal) -> String {
    "\(GainLossPercentDisplay.formatted(rate * 100)) p.a."
  }

  private var plColor: Color {
    guard let profitLoss = performance.profitLoss else { return .secondary }
    if profitLoss.isNegative { return .red }
    if profitLoss.isZero { return .primary }
    return .green
  }

  private func paColor(_ rate: Decimal) -> Color {
    if rate < 0 { return .red }
    if rate == 0 { return .primary }
    return .green
  }

  /// Surfaced via `.help(...)` on the unavailable p.a. tile.
  /// Distinguishes "not enough data" from "conversion broke" so the
  /// user knows whether to wait or retry.
  private var annualisedReturnUnavailableTooltip: String {
    if performance.firstFlowDate == nil {
      return "Not enough activity yet"
    }
    return "Annualised return unavailable — conversion may have failed"
  }

  // MARK: - Accessibility labels

  // currentValueAccessibilityLabel logic moved to
  // AccountPerformanceTileLabels (Domain Layer is strictly isolated
  // from UI copy per CLAUDE.md), so this view only invokes it.

  private var profitLossAccessibilityLabel: String {
    guard let profitLoss = performance.profitLoss else {
      return "Profit and Loss: Not available"
    }
    var label = "Profit and Loss: \(profitLoss.signedFormatted)"
    if let pct = profitLossPercentText {
      label += ", \(pct)"
    }
    return label
  }

  private var annualisedReturnAccessibilityLabel: String {
    guard let rate = performance.annualisedReturn else {
      return "Annualised Return: \(annualisedReturnUnavailableTooltip)"
    }
    var label = "Annualised Return: \(formattedPaPercent(rate))"
    if let since = sinceText {
      label += " \(since)"
    }
    return label
  }
}

private let tileDividerHeight: CGFloat = 50

// MARK: - Tile primitive

private struct Tile<Content: View, Subtitle: View>: View {
  let label: String
  @ViewBuilder let content: () -> Content
  @ViewBuilder let subtitle: () -> Subtitle

  init(
    label: String,
    @ViewBuilder content: @escaping () -> Content,
    @ViewBuilder subtitle: @escaping () -> Subtitle
  ) {
    self.label = label
    self.content = content
    self.subtitle = subtitle
  }

  init(
    label: String,
    @ViewBuilder content: @escaping () -> Content
  ) where Subtitle == EmptyView {
    self.label = label
    self.content = content
    self.subtitle = { EmptyView() }
  }

  var body: some View {
    VStack(spacing: 4) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      content()
      subtitle()
    }
    .frame(maxWidth: .infinity)
    .accessibilityElement(children: .combine)
  }
}

// MARK: - Previews

#Preview("Gain") {
  AccountPerformanceTiles(
    title: "Brokerage",
    performance: AccountPerformance(
      instrument: .AUD,
      currentValue: InstrumentAmount(quantity: 23_405, instrument: .AUD),
      totalContributions: InstrumentAmount(quantity: 21_605, instrument: .AUD),
      profitLoss: InstrumentAmount(quantity: 1_800, instrument: .AUD),
      profitLossPercent: Decimal(string: "0.083"),
      annualisedReturn: Decimal(string: "0.083"),
      firstFlowDate: Calendar.current.date(byAdding: .year, value: -3, to: Date()))
  )
  .frame(width: 720)
  .padding()
}

#Preview("Loss") {
  AccountPerformanceTiles(
    title: "Brokerage",
    performance: AccountPerformance(
      instrument: .AUD,
      currentValue: InstrumentAmount(quantity: 9_500, instrument: .AUD),
      totalContributions: InstrumentAmount(quantity: 10_000, instrument: .AUD),
      profitLoss: InstrumentAmount(quantity: -500, instrument: .AUD),
      profitLossPercent: Decimal(string: "-0.05"),
      annualisedReturn: Decimal(string: "-0.05"),
      firstFlowDate: Calendar.current.date(byAdding: .year, value: -1, to: Date()))
  )
  .frame(width: 720)
  .padding()
}

#Preview("Unavailable") {
  AccountPerformanceTiles(
    title: "Brokerage",
    performance: .unavailable(in: .AUD)
  )
  .frame(width: 720)
  .padding()
}

#Preview("No flows yet") {
  AccountPerformanceTiles(
    title: "Brokerage",
    performance: AccountPerformance(
      instrument: .AUD,
      currentValue: InstrumentAmount(quantity: 0, instrument: .AUD),
      totalContributions: InstrumentAmount(quantity: 0, instrument: .AUD),
      profitLoss: InstrumentAmount(quantity: 0, instrument: .AUD),
      profitLossPercent: nil,
      annualisedReturn: nil,
      firstFlowDate: nil)
  )
  .frame(width: 720)
  .padding()
}

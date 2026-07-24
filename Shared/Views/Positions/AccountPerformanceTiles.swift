// Shared/Views/Positions/AccountPerformanceTiles.swift
import SwiftUI

/// Three-tile horizontal strip rendering account-level lifetime numbers
/// from an `AccountPerformance`: Current Value (with the amount invested
/// beneath), Gain (dollar figure plus its total-return %), and Return (the
/// annualised rate, with a "since [first-flow-date]" subtitle). The Gain %
/// is a plain gain/invested ratio; the Return % is annualised — the two are
/// deliberately different measures, shown on separate tiles.
///
/// Used for both position-tracked accounts (performance supplied via
/// `PositionsViewInput.performance`) and manual-valuation accounts. Each
/// tile shows "—" / "Unavailable" rather than a partial sum when its
/// source field is `nil` — see Rule 11 in
/// `guides/INSTRUMENT_CONVERSION_GUIDE.md`.
struct AccountPerformanceTiles: View {
  let performance: AccountPerformance
  var oldestPriceDate: Date?

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 0) {
        currentValueTile
        Divider().frame(height: tileDividerHeight)
        profitLossTile
        Divider().frame(height: tileDividerHeight)
        annualisedReturnTile
      }
      if let oldestPriceDate {
        PriceDateDisclosure(oldestDate: oldestPriceDate)
          .frame(maxWidth: .infinity, alignment: .trailing)
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
      if performance.amountInvested != nil {
        Text(text)
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(.secondary)
      } else {
        // "Amount invested —" form: no number to monospace; tertiary
        // colour matches the Gain tile's `—` styling.
        Text(text)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
  }

  @ViewBuilder private var profitLossTile: some View {
    Tile(label: "Gain") {
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
    let tile = Tile(label: "Return") {
      if let rate = performance.annualisedReturn {
        Text(formattedAnnualReturn(rate))
          .font(.title3)
          .monospacedDigit()
          .foregroundStyle(paColor(rate))
          .help(annualisedReturnAvailableTooltip)
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
          .monospacedDigit()
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

  /// `+8.3% a year` / `−4.0% a year` / `0.0% a year`. Plain, global phrasing
  /// (BRAND_GUIDE — no jargon) in place of "p.a.". Uses the shared
  /// `GainLossPercentDisplay.formatted` so the percentage portion matches
  /// `PositionsTable.gainCell` and `PositionRow.trailingColumn`.
  private func formattedAnnualReturn(_ rate: Decimal) -> String {
    "\(GainLossPercentDisplay.formatted(rate * 100)) a year"
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

  /// `.help(...)`/hint tooltip on the available Return tile. Distinguishes
  /// the annualised rate from the Gain tile's simple ratio.
  private let annualisedReturnAvailableTooltip =
    "Average return each year since your first investment."

  /// Full-sentence reason the Return is unavailable, surfaced via `.help(...)`
  /// and the accessibility hint. Branches on the data actually present so the
  /// message is honest: the return is `nil` for three distinct reasons and
  /// only one of them is a conversion failure.
  private var annualisedReturnUnavailableTooltip: String {
    if performance.firstFlowDate == nil {
      return "Not enough activity yet"
    }
    if performance.currentValue == nil {
      return "Return unavailable — a price conversion may have failed"
    }
    return "Return unavailable — not enough time has passed yet"
  }

  /// The bare reason clause (no leading "Return") for the accessibility label,
  /// which already prefixes "Return: " — avoids a "Return: Return unavailable…"
  /// stutter under VoiceOver. Mirrors the three branches of the full tooltip.
  private var annualisedReturnUnavailableReason: String {
    if performance.firstFlowDate == nil {
      return "Not enough activity yet"
    }
    if performance.currentValue == nil {
      return "a price conversion may have failed"
    }
    return "not enough time has passed yet"
  }

  // MARK: - Accessibility labels

  // currentValueAccessibilityLabel logic moved to
  // AccountPerformanceTileLabels (Domain Layer is strictly isolated
  // from UI copy per CLAUDE.md), so this view only invokes it.

  private var profitLossAccessibilityLabel: String {
    guard let profitLoss = performance.profitLoss else {
      return "Gain: Unavailable"
    }
    var label = "Gain: \(profitLoss.signedFormatted)"
    if let pct = profitLossPercentText {
      label += ", \(pct)"
    }
    return label
  }

  private var annualisedReturnAccessibilityLabel: String {
    guard let rate = performance.annualisedReturn else {
      return "Return: \(annualisedReturnUnavailableReason)"
    }
    var label = "Return: \(formattedAnnualReturn(rate))"
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
    performance: AccountPerformance(
      instrument: .AUD,
      currentValue: InstrumentAmount(quantity: 23_405, instrument: .AUD),
      amountInvested: InstrumentAmount(quantity: 21_605, instrument: .AUD),
      profitLoss: InstrumentAmount(quantity: 1_800, instrument: .AUD),
      profitLossPercent: Decimal(string: "0.083"),
      annualisedReturn: Decimal(string: "0.083"),
      firstFlowDate: Calendar.current.date(byAdding: .year, value: -3, to: Date())),
    oldestPriceDate: Calendar.utc.date(
      from: DateComponents(year: 2026, month: 7, day: 23))
  )
  .frame(width: 720)
  .padding()
}

#Preview("Loss") {
  AccountPerformanceTiles(
    performance: AccountPerformance(
      instrument: .AUD,
      currentValue: InstrumentAmount(quantity: 9_500, instrument: .AUD),
      amountInvested: InstrumentAmount(quantity: 10_000, instrument: .AUD),
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
    performance: .unavailable(in: .AUD)
  )
  .frame(width: 720)
  .padding()
}

#Preview("No flows yet") {
  AccountPerformanceTiles(
    performance: AccountPerformance(
      instrument: .AUD,
      currentValue: InstrumentAmount(quantity: 0, instrument: .AUD),
      amountInvested: InstrumentAmount(quantity: 0, instrument: .AUD),
      profitLoss: InstrumentAmount(quantity: 0, instrument: .AUD),
      profitLossPercent: nil,
      annualisedReturn: nil,
      firstFlowDate: nil)
  )
  .frame(width: 720)
  .padding()
}

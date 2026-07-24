import SwiftUI

/// Total + optional P&L pill, with price provenance right-aligned on the
/// same row. The account/group name lives in the enclosing navigation title,
/// so repeating it here would add noise.
struct PositionsHeader: View {
  let input: PositionsViewInput

  var body: some View {
    ViewThatFits(in: .horizontal) {
      headerRow(priceStyle: .full)
      headerRow(priceStyle: .compact)
      VStack(spacing: 4) {
        headerRow(priceStyle: nil)
        if input.totalValue != nil, let oldestDate = input.priceDateRange?.lowerBound {
          PriceDateDisclosure(oldestDate: oldestDate)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 12)
  }

  private func headerRow(
    priceStyle: PriceDateDisclosureStyle?
  ) -> some View {
    HStack(alignment: .firstTextBaseline) {
      if let total = input.totalValue {
        Text(total.formatted)
          .font(.headline)
          .monospacedDigit()
          .accessibilityLabel("Total \(total.formatted)")
      } else {
        Text("Unavailable")
          .font(.headline)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Total unavailable")
      }
      if input.showsPLPill, let gain = input.totalGainLoss, let total = input.totalValue {
        plPill(gain: gain, total: total)
      }
      Spacer()
      if input.totalValue != nil,
        let oldestDate = input.priceDateRange?.lowerBound,
        let priceStyle
      {
        PriceDateDisclosure(oldestDate: oldestDate, style: priceStyle)
      }
    }
  }

  private func plPill(gain: InstrumentAmount, total: InstrumentAmount) -> some View {
    let cost = total - gain
    let percent: Decimal = cost.quantity == 0 ? 0 : gain.quantity / cost.quantity * 100
    let label = "\(gain.signedFormatted) (\(GainLossPercentDisplay.formatted(percent)))"
    return Text(label)
      .font(.caption.weight(.semibold))
      .monospacedDigit()
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(
        gainBackground(gain).opacity(0.15),
        in: Capsule()
      )
      .foregroundStyle(gainColor(gain))
      .accessibilityLabel(plPillAccessibilityLabel(gain: gain, percent: percent))
  }

  /// Foreground colour for gain / loss / zero — matches PositionRow + PositionsTable.
  private func gainColor(_ gain: InstrumentAmount) -> Color {
    if gain.isNegative { return .red }
    if gain.isZero { return .primary }
    return .green
  }

  /// Background tint for the pill capsule. Mirrors `gainColor` but always
  /// returns a non-`.primary` colour so the capsule has a visible fill.
  /// Zero-gain still uses `.green` for the capsule (with low opacity) so
  /// the pill doesn't disappear when displayed.
  private func gainBackground(_ gain: InstrumentAmount) -> Color {
    gain.isNegative ? .red : .green
  }

  private func plPillAccessibilityLabel(gain: InstrumentAmount, percent: Decimal) -> String {
    // Locale-aware one-decimal-place body (e.g. `12.3` in en_US,
    // `12,3` in de_DE). Drops the sign and `%` so the surrounding
    // English phrasing carries the direction.
    let absPercent = percent < 0 ? -percent : percent
    let pctBody = absPercent.formatted(
      .number.precision(.fractionLength(1)).grouping(.never))
    if gain.isNegative {
      return "Down \((-gain).formatted), \(pctBody) percent"
    }
    if gain.isZero {
      return "No change"
    }
    return "Up \(gain.formatted), \(pctBody) percent"
  }
}

#Preview("Gain") {
  PositionsHeader(
    input: PositionsViewInput(
      title: "Brokerage",
      hostCurrency: .AUD,
      positions: [
        ValuedPosition(
          instrument: Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP"),
          quantity: 250,
          unitPrice: nil,
          costBasis: InstrumentAmount(quantity: 10_125, instrument: .AUD),
          value: InstrumentAmount(quantity: 11_325, instrument: .AUD),
          oldestPriceDate: Calendar.utc.date(
            from: DateComponents(year: 2026, month: 7, day: 23))
        )
      ],
      historicalValue: nil
    )
  )
  .frame(width: 420)
}

#Preview("Loss") {
  PositionsHeader(
    input: PositionsViewInput(
      title: "Brokerage",
      hostCurrency: .AUD,
      positions: [
        ValuedPosition(
          instrument: Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP"),
          quantity: 250,
          unitPrice: nil,
          costBasis: InstrumentAmount(quantity: 11_325, instrument: .AUD),
          value: InstrumentAmount(quantity: 10_125, instrument: .AUD)
        )
      ],
      historicalValue: nil
    )
  )
  .frame(width: 420)
}

#Preview("Unavailable") {
  PositionsHeader(
    input: PositionsViewInput(
      title: "Brokerage",
      hostCurrency: .AUD,
      positions: [
        ValuedPosition(
          instrument: Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP"),
          quantity: 250,
          unitPrice: nil,
          costBasis: InstrumentAmount(quantity: 10_000, instrument: .AUD),
          value: nil
        )
      ],
      historicalValue: nil
    )
  )
  .frame(width: 420)
}

// swiftlint:disable multiline_arguments

import SwiftUI

/// Single-row presentation in `PositionsTable`. Used by both the wide
/// (`Table`) layout (where columns position the cells) and the narrow
/// (`List`) layout (where the row composes its own two-line layout).
///
/// Failed valuations render as `—` per `guides/UI_GUIDE.md`. Signs are
/// preserved across value, cost, and gain — the row never `abs()`s an amount.
struct PositionRow: View {
  let row: ValuedPosition

  // Rows breathe a little more under touch (12pt) than under a pointer
  // (8pt), per `guides/UI_GUIDE.md`. `@ScaledMetric` so the padding tracks
  // Dynamic Type, matching `TransactionRowView`.
  #if os(macOS)
    @ScaledMetric private var verticalPadding: CGFloat = 8
  #else
    @ScaledMetric private var verticalPadding: CGFloat = 12
  #endif

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      leadingColumn
      Spacer()
      trailingColumn
    }
    .padding(.vertical, verticalPadding)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
  }

  private var leadingColumn: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 6) {
        KindBadge(kind: row.instrument.kind)
        Text(row.instrument.name)
          .font(.headline)
      }
      if let secondary = secondaryIdentifier {
        Text(secondary)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Text(row.quantityCaption)
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
  }

  private var trailingColumn: some View {
    VStack(alignment: .trailing, spacing: 2) {
      if let value = row.value {
        Text(value.formatted)
          .font(.body)
          .monospacedDigit()
      } else {
        Text("—")
          .foregroundStyle(.tertiary)
      }
      if let gain = row.gainLoss {
        Text(captionText(for: gain))
          .font(.caption)
          .monospacedDigit()
          .foregroundStyle(gainColor(gain))
      }
    }
  }

  /// `"+$1,200  +12.3%"` / `"−$50  −5.0%"`. When `costBasis` is missing,
  /// falls back to `gain.signedFormatted` only (no trailing space). The
  /// percent segment is delegated to `GainLossPercentDisplay.formatted`
  /// so this row stays byte-identical with `PositionsTable.gainCell`.
  private func captionText(for gain: InstrumentAmount) -> String {
    guard let pct = row.gainLossPercent else { return gain.signedFormatted }
    return "\(gain.signedFormatted)  \(GainLossPercentDisplay.formatted(pct))"
  }

  private var secondaryIdentifier: String? {
    switch row.instrument.kind {
    case .stock: return row.instrument.exchange
    case .cryptoToken:
      if let chainId = row.instrument.chainId {
        return Instrument.chainName(for: chainId)
      }
      return nil
    case .fiatCurrency: return nil
    }
  }

  private func gainColor(_ gain: InstrumentAmount) -> Color {
    if gain.isNegative { return .red }
    if gain.isZero { return .primary }
    return .green
  }

  private var accessibilityLabel: String {
    var parts: [String] = [row.instrument.name, row.quantityCaption]
    if let value = row.value {
      parts.append("valued at \(value.formatted)")
    } else {
      parts.append("value unavailable")
    }
    if let gain = row.gainLoss {
      let pctSuffix = GainLossPercentDisplay.accessibilitySuffix(row.gainLossPercent)
      if gain.isNegative {
        parts.append("loss of \((-gain).formatted)\(pctSuffix)")
      } else if gain.isZero {
        parts.append(pctSuffix.isEmpty ? "no change" : "no change\(pctSuffix)")
      } else {
        parts.append("gain of \(gain.formatted)\(pctSuffix)")
      }
    }
    return parts.joined(separator: ", ")
  }
}

/// Coloured badge prefix for a row, distinguishing instrument kinds at a
/// glance. Colours are semantic (no hardcoded RGB).
struct KindBadge: View {
  let kind: Instrument.Kind

  var body: some View {
    let (label, tint): (String, Color) = {
      switch kind {
      case .stock: return ("S", .blue)
      case .cryptoToken: return ("C", .orange)
      case .fiatCurrency: return ("$", .indigo)
      }
    }()
    Text(label)
      .font(.caption2.weight(.bold))
      .foregroundStyle(.white)
      .frame(width: 18, height: 18)
      .background(tint, in: RoundedRectangle(cornerRadius: 4))
      .accessibilityHidden(true)
  }
}

private func previewRows() -> [ValuedPosition] {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  let aud = Instrument.AUD
  return [
    ValuedPosition(
      instrument: bhp, quantity: 250,
      unitPrice: InstrumentAmount(quantity: 45.30, instrument: aud),
      costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
      value: InstrumentAmount(quantity: 11_325, instrument: aud)),
    ValuedPosition(
      instrument: eth, quantity: 2.45,
      unitPrice: InstrumentAmount(quantity: 4_000, instrument: aud),
      costBasis: InstrumentAmount(quantity: 7_500, instrument: aud),
      value: InstrumentAmount(quantity: 9_800, instrument: aud)),
    ValuedPosition(
      instrument: aud, quantity: 1_520,
      unitPrice: nil, costBasis: nil,
      value: InstrumentAmount(quantity: 1_520, instrument: aud)),
    ValuedPosition(
      instrument: bhp, quantity: 100,
      unitPrice: nil, costBasis: nil, value: nil),
    ValuedPosition(
      instrument: bhp, quantity: 50,
      unitPrice: InstrumentAmount(quantity: 30, instrument: aud),
      costBasis: InstrumentAmount(quantity: 2_000, instrument: aud),
      value: InstrumentAmount(quantity: 1_500, instrument: aud)),
    // Zero cost basis: gainLoss is non-nil (5,000 − 0 = 5,000) but
    // gainLossPercent is nil (division by zero). Exercises the
    // nil-percent-but-non-nil-gain branch of captionText.
    ValuedPosition(
      instrument: bhp, quantity: 100,
      unitPrice: InstrumentAmount(quantity: 50, instrument: aud),
      costBasis: InstrumentAmount(quantity: 0, instrument: aud),
      value: InstrumentAmount(quantity: 5_000, instrument: aud)),
  ]
}

#Preview("rows") {
  List {
    ForEach(previewRows()) { row in
      PositionRow(row: row)
    }
  }
  .frame(width: 420)
}

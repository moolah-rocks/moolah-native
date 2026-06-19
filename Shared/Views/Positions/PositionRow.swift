import SwiftUI

/// Single-row presentation in `PositionsTable`. Used by both the wide
/// (`Table`) layout (where columns position the cells) and the narrow
/// (`List`) layout (where the row composes its own two-line layout).
///
/// Failed valuations render as `—` per `guides/UI_GUIDE.md`. Signs are
/// preserved across value, cost, and gain — the row never `abs()`s an amount.
struct PositionRow: View {
  let row: AssetHolding

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
        KindBadge(kind: row.kind)
        Text(row.name)
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
          .monospacedDigit()
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
    switch row.kind {
    case .stock: return row.exchange
    case .cryptoToken: return row.chainSummaryLabel
    case .fiatCurrency: return nil
    }
  }

  private func gainColor(_ gain: InstrumentAmount) -> Color {
    if gain.isNegative { return .red }
    if gain.isZero { return .primary }
    return .green
  }

  private var accessibilityLabel: String {
    var parts: [String] = [row.name]
    if let chains = row.chainAccessibilitySummary {
      parts.append("on \(chains)")
    }
    parts.append(row.quantityCaption)
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

private func previewAmount(_ value: Decimal) -> InstrumentAmount {
  InstrumentAmount(quantity: value, instrument: .AUD)
}

private func previewStockRow() -> AssetHolding {
  AssetHolding(
    id: "ASX:BHP.AX",
    kind: .stock,
    name: "BHP",
    displayLabel: "BHP.AX",
    decimals: 0,
    currencyCode: nil,
    chainId: nil,
    exchange: "ASX",
    quantity: 250,
    unitPrice: previewAmount(45.30),
    costBasis: previewAmount(10_125),
    value: previewAmount(11_325),
    contributingInstrumentIds: ["ASX:BHP.AX"],
    contributingChainIds: [])
}

private func previewCryptoRow() -> AssetHolding {
  AssetHolding(
    id: "ethereum",
    kind: .cryptoToken,
    name: "Ethereum",
    displayLabel: "ETH",
    decimals: 18,
    currencyCode: nil,
    chainId: nil,
    exchange: nil,
    quantity: Decimal(string: "12.95694") ?? 0,
    unitPrice: previewAmount(4_000),
    costBasis: previewAmount(35_000),
    value: previewAmount(51_827),
    contributingInstrumentIds: ["1:native", "10:native"],
    contributingChainIds: [1, 10])
}

private func previewFiatRow() -> AssetHolding {
  AssetHolding(
    id: "AUD",
    kind: .fiatCurrency,
    name: "AUD",
    displayLabel: "$",
    decimals: 2,
    currencyCode: "AUD",
    chainId: nil,
    exchange: nil,
    quantity: 1_520,
    unitPrice: nil,
    costBasis: nil,
    value: previewAmount(1_520),
    contributingInstrumentIds: ["AUD"],
    contributingChainIds: [])
}

private func previewRows() -> [AssetHolding] {
  [previewStockRow(), previewCryptoRow(), previewFiatRow()]
}

#Preview("rows") {
  List {
    ForEach(previewRows()) { row in
      PositionRow(row: row)
    }
  }
  .frame(width: 420)
}

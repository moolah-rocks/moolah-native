// swiftlint:disable multiline_arguments

import SwiftUI

/// Responsive table of `ValuedPosition`s. On wide layouts (macOS, regular iOS
/// width) renders a `Table` with sortable columns. On compact layouts falls
/// back to a `List` of `PositionRow`s.
///
/// Group subtotals only render when more than one `Instrument.Kind` is
/// present (per `PositionsViewInput.showsGroupSubtotals`).
struct PositionsTable: View {
  let input: PositionsViewInput
  @Binding var selection: Instrument?

  @Environment(\.horizontalSizeClass) private var sizeClass

  @State private var sortOrder: [KeyPathComparator<ValuedPosition>] = [
    .init(\.valueQuantity, order: .reverse)
  ]

  var body: some View {
    Group {
      #if os(macOS)
        wideLayout
      #else
        if sizeClass == .regular {
          wideLayout
        } else {
          narrowLayout
        }
      #endif
    }
  }

  private var groups: [InstrumentGroup] {
    InstrumentGroup.from(input.positions)
  }

  // MARK: - Wide

  @ViewBuilder private var wideLayout: some View {
    let sortedRows = groups.flatMap(\.rows).sorted(using: sortOrder)
    Table(sortedRows, selection: rowSelectionBinding, sortOrder: $sortOrder) {
      TableColumn("Instrument", value: \.instrument.name) { row in
        instrumentCell(for: row)
      }
      // Full word, not "Qty": macOS `Table` reads the column header to
      // VoiceOver, where "Qty" would be spoken as an abbreviation.
      TableColumn("Quantity", value: \.quantity) { row in
        Text(row.quantityFormatted).monospacedDigit()
      }
      TableColumn("Unit Price", value: \.unitPriceQuantity) { row in
        amountCell(row.unitPrice)
      }
      TableColumn("Cost", value: \.costBasisQuantity) { row in
        amountCell(row.costBasis)
      }
      TableColumn("Value", value: \.valueQuantity) { row in
        amountCell(row.value)
      }
      TableColumn("Gain", value: \.gainQuantity) { row in
        gainCell(row)
      }
    }
  }

  @ViewBuilder
  private func instrumentCell(for row: ValuedPosition) -> some View {
    HStack(spacing: 6) {
      KindBadge(kind: row.instrument.kind)
      VStack(alignment: .leading) {
        Text(row.instrument.name)
        if let exchange = row.instrument.exchange {
          Text(exchange).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    // The wide `Table` gives this cell a fixed column width, so the caption
    // (exchange / chain summary) clips rather than wraps at the largest
    // accessibility sizes. Cap Dynamic Type at the guide's standard ceiling
    // (`guides/UI_GUIDE.md` §4: `.medium...accessibility3`) — the tradeoff is
    // that accessibility4+ users see this cell at accessibility3 scale. The cap
    // is scoped to the instrument cell so the numeric columns keep scaling for
    // low-vision readability; the narrow `List` layout (`PositionRow`) keeps the
    // full range since it can wrap.
    .dynamicTypeSize(...DynamicTypeSize.accessibility3)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(instrumentLabel(for: row))
  }

  @ViewBuilder
  private func amountCell(_ amount: InstrumentAmount?) -> some View {
    if let amount {
      Text(amount.formatted).monospacedDigit()
    } else {
      Text("—").foregroundStyle(.tertiary)
    }
  }

  @ViewBuilder
  private func gainCell(_ row: ValuedPosition) -> some View {
    if let gain = row.gainLoss {
      HStack(spacing: 4) {
        Text(gain.signedFormatted)
          .monospacedDigit()
          .foregroundStyle(gainColor(gain))
        if let pct = row.gainLossPercent {
          Text(GainLossPercentDisplay.formatted(pct))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(gainColor(gain))
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(gainAccessibilityLabel(gain: gain, percent: row.gainLossPercent))
    } else {
      Text("—").foregroundStyle(.tertiary)
    }
  }

  /// Accessibility label combining the dollar gain and percent: e.g.
  /// "gain of $1,200, up 12.3 percent" / "loss of $50, down 5.0 percent".
  /// Per `guides/UI_GUIDE.md` every gain renders an explicit
  /// accessibility label so VoiceOver doesn't read "+12%" as ambiguous.
  private func gainAccessibilityLabel(
    gain: InstrumentAmount, percent: Decimal?
  ) -> String {
    let pctText = GainLossPercentDisplay.accessibilitySuffix(percent)
    if gain.isNegative {
      return "loss of \((-gain).formatted)\(pctText)"
    }
    if gain.isZero {
      return pctText.isEmpty ? "no change" : "no change\(pctText)"
    }
    return "gain of \(gain.formatted)\(pctText)"
  }

  /// `Table` selects on `id` (which is `instrument.id`); we adapt that to
  /// our `Instrument?` selection binding.
  private var rowSelectionBinding: Binding<Set<String>> {
    Binding(
      get: { selection.map { [$0.id] } ?? [] },
      set: { ids in
        if let id = ids.first,
          let instrument = input.positions.first(where: { $0.id == id })?.instrument
        {
          selection = (selection?.id == id) ? nil : instrument
        } else {
          selection = nil
        }
      }
    )
  }

  // MARK: - Narrow

  @ViewBuilder private var narrowLayout: some View {
    List(selection: narrowSelectionBinding) {
      ForEach(groups) { group in
        groupContent(for: group)
      }
    }
    #if !os(macOS)
      .listStyle(.plain)
    #endif
  }

  @ViewBuilder
  private func groupContent(for group: InstrumentGroup) -> some View {
    if input.showsGroupSubtotals {
      Section(group.title) {
        ForEach(group.rows) { row in
          PositionRow(row: row).tag(row.id)
        }
      }
    } else {
      ForEach(group.rows) { row in
        PositionRow(row: row).tag(row.id)
      }
    }
  }

  private var narrowSelectionBinding: Binding<String?> {
    Binding(
      get: { selection?.id },
      set: { id in
        if let id, let instrument = input.positions.first(where: { $0.id == id })?.instrument {
          selection = (selection?.id == id) ? nil : instrument
        } else {
          selection = nil
        }
      }
    )
  }

  // MARK: - Helpers

  private func gainColor(_ gain: InstrumentAmount) -> Color {
    if gain.isNegative { return .red }
    if gain.isZero { return .primary }
    return .green
  }

  private func instrumentLabel(for row: ValuedPosition) -> String {
    let kindWord: String = {
      switch row.instrument.kind {
      case .stock: return "Stock"
      case .cryptoToken: return "Crypto"
      case .fiatCurrency: return "Cash"
      }
    }()
    if let exchange = row.instrument.exchange {
      return "\(row.instrument.name), \(kindWord), \(exchange)"
    }
    return "\(row.instrument.name), \(kindWord)"
  }
}

/// Internal grouping helper — splits the rows into Stocks / Crypto / Cash
/// in spec order. Each group is empty if no row of that kind appears.
struct InstrumentGroup: Identifiable {
  enum Kind { case stocks, crypto, cash }

  let kind: Kind
  let rows: [ValuedPosition]
  var id: String {
    switch kind {
    case .stocks: return "stocks"
    case .crypto: return "crypto"
    case .cash: return "cash"
    }
  }
  var title: String {
    switch kind {
    case .stocks: return "Stocks"
    case .crypto: return "Crypto"
    case .cash: return "Cash"
    }
  }

  static func from(_ rows: [ValuedPosition]) -> [InstrumentGroup] {
    let stocks = rows.filter { $0.instrument.kind == .stock }
    let crypto = rows.filter { $0.instrument.kind == .cryptoToken }
    let cash = rows.filter { $0.instrument.kind == .fiatCurrency }
    return [
      .init(kind: .stocks, rows: stocks),
      .init(kind: .crypto, rows: crypto),
      .init(kind: .cash, rows: cash),
    ].filter { !$0.rows.isEmpty }
  }
}

private func mixedPositionsInput() -> PositionsViewInput {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")
  let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  let aud = Instrument.AUD
  return PositionsViewInput(
    title: "Brokerage", hostCurrency: aud,
    positions: [
      ValuedPosition(
        instrument: bhp, quantity: 250,
        unitPrice: InstrumentAmount(quantity: 45.30, instrument: aud),
        costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
        value: InstrumentAmount(quantity: 11_325, instrument: aud)),
      ValuedPosition(
        instrument: cba, quantity: 80,
        unitPrice: InstrumentAmount(quantity: 120, instrument: aud),
        costBasis: InstrumentAmount(quantity: 9_000, instrument: aud),
        value: InstrumentAmount(quantity: 9_600, instrument: aud)),
      ValuedPosition(
        instrument: eth, quantity: 2.45,
        unitPrice: InstrumentAmount(quantity: 4_000, instrument: aud),
        costBasis: InstrumentAmount(quantity: 7_500, instrument: aud),
        value: InstrumentAmount(quantity: 9_800, instrument: aud)),
      ValuedPosition(
        instrument: aud, quantity: 2_480,
        unitPrice: nil, costBasis: nil,
        value: InstrumentAmount(quantity: 2_480, instrument: aud)),
    ],
    historicalValue: nil)
}

#Preview("PositionsTable - mixed wide") {
  PositionsTable(input: mixedPositionsInput(), selection: .constant(nil))
    .frame(width: 720, height: 360)
}

#Preview("PositionsTable - conversion failure") {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let aud = Instrument.AUD
  let input = PositionsViewInput(
    title: "Brokerage",
    hostCurrency: aud,
    positions: [
      ValuedPosition(
        instrument: bhp, quantity: 250,
        unitPrice: nil, costBasis: nil, value: nil)
    ],
    historicalValue: nil
  )
  return PositionsTable(input: input, selection: .constant(nil))
    .frame(width: 720, height: 240)
}

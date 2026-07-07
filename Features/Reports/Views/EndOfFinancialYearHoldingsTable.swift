import SwiftUI

#if os(macOS)
  struct EndOfFinancialYearHoldingsTable: View {
    enum Layout {
      case regular
      case compact
    }

    let rows: [InstrumentProfitLoss]
    let profileInstrument: Instrument
    let layout: Layout
    @State private var sort: HoldingsSort = .gain(ascending: false)

    init(
      rows: [InstrumentProfitLoss],
      profileInstrument: Instrument,
      layout: Layout = .regular
    ) {
      self.rows = rows
      self.profileInstrument = profileInstrument
      self.layout = layout
    }

    private var sortedRows: [InstrumentProfitLoss] {
      sort.sorted(rows)
    }

    var body: some View {
      VStack(spacing: 0) {
        header
        ForEach(sortedRows) { row in
          Divider()
          rowView(row)
        }
      }
      .font(.body)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.background.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .strokeBorder(.separator.opacity(0.45))
      }
    }

    private var header: some View {
      HStack(spacing: 0) {
        sortHeader(
          "Instrument",
          .instrument,
          width: HoldingsTableLayout.instrument(layout),
          alignment: .leading)
        columnSpacer
        sortHeader(
          "Quantity", .quantity, width: HoldingsTableLayout.quantity(layout), alignment: .trailing)
        if layout == .regular {
          columnSpacer
          sortHeader(
            "Cost held", .cost, width: HoldingsTableLayout.money(layout), alignment: .trailing)
        }
        columnSpacer
        sortHeader(
          "End value", .value, width: HoldingsTableLayout.money(layout), alignment: .trailing)
        columnSpacer
        sortHeader(
          "Gain/loss held", .gain, width: HoldingsTableLayout.money(layout), alignment: .trailing)
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, HoldingsTableLayout.horizontalPadding)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.quaternary.opacity(0.35))
    }

    private func rowView(_ row: InstrumentProfitLoss) -> some View {
      HStack(spacing: 0) {
        instrumentCell(for: row)
          .frame(width: HoldingsTableLayout.instrument(layout), alignment: .leading)
        columnSpacer
        Text(row.currentQuantity.formatted())
          .monospacedDigit()
          .frame(width: HoldingsTableLayout.quantity(layout), alignment: .trailing)
        if layout == .regular {
          columnSpacer
          amountCell(remainingCostBasis(row))
            .frame(width: HoldingsTableLayout.money(layout), alignment: .trailing)
        }
        columnSpacer
        amountCell(row.currentValue)
          .frame(width: HoldingsTableLayout.money(layout), alignment: .trailing)
        columnSpacer
        gainLossCell(row.unrealizedGain)
          .frame(width: HoldingsTableLayout.money(layout), alignment: .trailing)
      }
      .padding(.horizontal, HoldingsTableLayout.horizontalPadding)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(accessibilityLabel(for: row))
    }

    private func sortHeader(
      _ title: String,
      _ column: HoldingsSort.Column,
      width: CGFloat,
      alignment: Alignment
    ) -> some View {
      Button {
        sort = sort.isCurrent(column) ? sort.toggled : column.defaultSort
      } label: {
        HStack(spacing: 4) {
          Text(title)
          Image(systemName: sortIconName(for: column))
            .font(.caption2)
            .foregroundStyle(sort.isCurrent(column) ? .primary : .tertiary)
        }
        .frame(width: width, alignment: alignment)
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Sort by \(title)")
      .accessibilityValue(sortAccessibilityValue(for: column))
    }

    private var columnSpacer: some View {
      Spacer(minLength: HoldingsTableLayout.columnSpacing)
    }

    private func sortIconName(for column: HoldingsSort.Column) -> String {
      guard sort.isCurrent(column) else { return "arrow.up.arrow.down" }
      return sort.isAscending ? "chevron.up" : "chevron.down"
    }

    private func sortAccessibilityValue(for column: HoldingsSort.Column) -> String {
      guard sort.isCurrent(column) else { return "not sorted" }
      return sort.isAscending ? "currently ascending" : "currently descending"
    }

    private func instrumentCell(for row: InstrumentProfitLoss) -> some View {
      VStack(alignment: .leading, spacing: 1) {
        Text(row.instrument.displayLabel)
        if row.instrument.name != row.instrument.displayLabel {
          Text(row.instrument.name)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .lineLimit(1)
      .accessibilityElement(children: .combine)
    }

    private func amountCell(_ quantity: Decimal) -> some View {
      Text(formattedAmount(quantity))
        .monospacedDigit()
    }

    private func gainLossCell(_ quantity: Decimal) -> some View {
      ReportGainLossText(
        amount: InstrumentAmount(quantity: quantity, instrument: profileInstrument))
    }

    private func accessibilityLabel(for row: InstrumentProfitLoss) -> String {
      [
        "Instrument: \(row.instrument.displayLabel)",
        "Quantity: \(row.currentQuantity.formatted())",
        "Cost held: \(formattedAmount(remainingCostBasis(row)))",
        "End value: \(formattedAmount(row.currentValue))",
        "Gain or loss held: \(formattedAmount(row.unrealizedGain))",
      ].joined(separator: ", ")
    }

    private func formattedAmount(_ quantity: Decimal) -> String {
      InstrumentAmount(quantity: quantity, instrument: profileInstrument).formatted
    }
  }

  private func remainingCostBasis(_ row: InstrumentProfitLoss) -> Decimal {
    row.currentValue - row.unrealizedGain
  }

#endif

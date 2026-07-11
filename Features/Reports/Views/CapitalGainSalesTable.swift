import SwiftUI

struct CapitalGainSalesTable: View {
  enum Layout {
    case regular
    case compact
  }

  let sales: [CapitalGainSale]
  let profileInstrument: Instrument
  let layout: Layout
  @Binding var sort: CapitalGainSaleSort

  @State private var expandedSaleIds: Set<CapitalGainSaleIdentifier>

  init(
    sales: [CapitalGainSale],
    profileInstrument: Instrument,
    layout: Layout = .regular,
    sort: Binding<CapitalGainSaleSort>,
    initiallyExpanded: Set<CapitalGainSaleIdentifier> = []
  ) {
    self.sales = sales
    self.profileInstrument = profileInstrument
    self.layout = layout
    self._sort = sort
    self._expandedSaleIds = State(initialValue: initiallyExpanded)
  }

  var body: some View {
    VStack(spacing: 0) {
      header
      ForEach(Array(sales.enumerated()), id: \.element.id) { index, sale in
        saleRow(sale)
        if expandedSaleIds.contains(sale.id) {
          lotRows(for: sale)
        }
        if index < sales.count - 1 {
          Divider()
            .padding(.leading, SalesTableLayout.dividerInset)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(.separator.opacity(0.45))
    }
  }

  private var header: some View {
    HStack(spacing: 0) {
      Color.clear
        .frame(width: SalesTableLayout.disclosure)
      columnSpacer
      sortHeader(
        "Instrument", .instrument, width: SalesTableLayout.instrument(layout), alignment: .leading)
      columnSpacer
      sortHeader("Sold", .sold, width: SalesTableLayout.date(layout), alignment: .leading)
      columnSpacer
      sortHeader(
        "Quantity", .quantity, width: SalesTableLayout.quantity(layout), alignment: .trailing)
      columnSpacer
      sortHeader(
        layout == .compact ? "Avg cost" : "Average cost",
        .volumeWeightedCost,
        width: SalesTableLayout.money(layout),
        alignment: .trailing)
      columnSpacer
      sortHeader("Proceeds", .proceeds, width: SalesTableLayout.money(layout), alignment: .trailing)
      columnSpacer
      sortHeader("Gain", .gain, width: SalesTableLayout.money(layout), alignment: .trailing)
      columnSpacer
      sortHeader(
        layout == .compact ? "12-mo gain" : "12-month gain",
        .discountEligibleGain,
        width: SalesTableLayout.discountGain(layout),
        alignment: .trailing)
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(.secondary)
    .padding(.horizontal, SalesTableLayout.horizontalPadding)
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.35))
  }

  private func saleRow(_ sale: CapitalGainSale) -> some View {
    HStack(spacing: 0) {
      disclosureButton(for: sale)
      columnSpacer
      instrumentCell(for: sale)
        .frame(width: SalesTableLayout.instrument(layout), alignment: .leading)
      columnSpacer
      Text(TaxReportPresentation.dateLabel(sale.sellDate))
        .monospacedDigit()
        .frame(width: SalesTableLayout.date(layout), alignment: .leading)
      columnSpacer
      quantityCell(sale.quantity, instrument: sale.instrument)
        .frame(width: SalesTableLayout.quantity(layout), alignment: .trailing)
      columnSpacer
      amountCell(sale.volumeWeightedCost)
        .frame(width: SalesTableLayout.money(layout), alignment: .trailing)
      columnSpacer
      amountCell(sale.proceeds)
        .frame(width: SalesTableLayout.money(layout), alignment: .trailing)
      columnSpacer
      gainLossCell(sale.gain)
        .frame(width: SalesTableLayout.money(layout), alignment: .trailing)
      columnSpacer
      gainLossCell(sale.discountEligibleGain)
        .frame(width: SalesTableLayout.discountGain(layout), alignment: .trailing)
    }
    .font(.body)
    .padding(.horizontal, SalesTableLayout.horizontalPadding)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(saleAccessibilityLabel(for: sale))
    .accessibilityHint("Press to show or hide purchases used for this sale.")
    .accessibilityAddTraits(.isButton)
    .accessibilityAction {
      toggleExpanded(sale.id)
    }
  }

  private func lotRows(for sale: CapitalGainSale) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Purchases used for this sale")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
      ScrollView(.horizontal) {
        VStack(spacing: 0) {
          lotHeader
          Divider()
          ForEach(Array(sale.lots.enumerated()), id: \.element.id) { index, lot in
            lotRow(lot, instrument: sale.instrument)
            if index < sale.lots.count - 1 {
              Divider()
            }
          }
        }
        .frame(width: SalesTableLayout.lotWidth, alignment: .leading)
      }
      .font(.caption)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 6))
    .padding(.leading, SalesTableLayout.detailLeadingPadding)
    .padding(.trailing, SalesTableLayout.horizontalPadding)
    .padding(.bottom, 10)
  }

  private var lotHeader: some View {
    HStack(spacing: SalesTableLayout.lotColumnSpacing) {
      lotHeader("Purchased", width: SalesTableLayout.lotDate, alignment: .leading)
      lotHeader("Quantity", width: SalesTableLayout.lotQuantity, alignment: .trailing)
      lotHeader("Cost", width: SalesTableLayout.lotMoney, alignment: .trailing)
      lotHeader("Proceeds", width: SalesTableLayout.lotMoney, alignment: .trailing)
      lotHeader("Gain", width: SalesTableLayout.lotMoney, alignment: .trailing)
      lotHeader("Holding", width: SalesTableLayout.lotHolding, alignment: .leading)
    }
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func lotRow(
    _ lot: CapitalGainSaleLot,
    instrument: Instrument
  ) -> some View {
    HStack(spacing: SalesTableLayout.lotColumnSpacing) {
      Text(TaxReportPresentation.dateLabel(lot.acquiredDate))
        .monospacedDigit()
        .frame(width: SalesTableLayout.lotDate, alignment: .leading)
      quantityCell(lot.quantity, instrument: instrument)
        .frame(width: SalesTableLayout.lotQuantity, alignment: .trailing)
      amountCell(lot.costBasis)
        .frame(width: SalesTableLayout.lotMoney, alignment: .trailing)
      amountCell(lot.proceeds)
        .frame(width: SalesTableLayout.lotMoney, alignment: .trailing)
      gainLossCell(lot.gain)
        .frame(width: SalesTableLayout.lotMoney, alignment: .trailing)
      Text(TaxReportPresentation.holdingPeriodLabel(for: lot.event))
        .lineLimit(1)
        .frame(width: SalesTableLayout.lotHolding, alignment: .leading)
    }
    .foregroundStyle(.primary)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(lotAccessibilityLabel(for: lot, instrument: instrument))
  }
}

extension CapitalGainSalesTable {
  private var columnSpacer: some View {
    Spacer(minLength: SalesTableLayout.columnSpacing)
  }

  private func sortHeader(
    _ title: String,
    _ column: CapitalGainSaleSort.Column,
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

  private func sortIconName(for column: CapitalGainSaleSort.Column) -> String {
    guard sort.isCurrent(column) else { return "arrow.up.arrow.down" }
    return sort.isAscending ? "chevron.up" : "chevron.down"
  }

  private func sortAccessibilityValue(for column: CapitalGainSaleSort.Column) -> String {
    guard sort.isCurrent(column) else { return "not sorted" }
    return sort.isAscending ? "currently ascending" : "currently descending"
  }

  private func disclosureButton(for sale: CapitalGainSale) -> some View {
    Button {
      toggleExpanded(sale.id)
    } label: {
      Image(systemName: expandedSaleIds.contains(sale.id) ? "chevron.down" : "chevron.right")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: SalesTableLayout.disclosure, height: SalesTableLayout.disclosure)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(disclosureAccessibilityLabel(for: sale))
  }

  private func disclosureAccessibilityLabel(
    for sale: CapitalGainSale
  ) -> String {
    let action = expandedSaleIds.contains(sale.id) ? "Hide" : "Show"
    return
      "\(action) purchases used for \(sale.instrument.displayLabel) sold \(TaxReportPresentation.dateLabel(sale.sellDate))"
  }

  private func saleAccessibilityLabel(for sale: CapitalGainSale) -> String {
    let expanded = expandedSaleIds.contains(sale.id) ? "expanded" : "collapsed"
    var parts = [
      "Instrument: \(sale.instrument.displayLabel)",
      "Sold: \(TaxReportPresentation.dateLabel(sale.sellDate))",
      "Quantity: \(formattedQuantity(sale.quantity, instrument: sale.instrument))",
      "Average cost: \(formattedAmount(sale.volumeWeightedCost))",
      "Proceeds: \(formattedAmount(sale.proceeds))",
      "Gain: \(formattedAmount(sale.gain))",
      "12-month gain: \(formattedAmount(sale.discountEligibleGain))",
    ]
    if let ownerLabel = sale.ownerLabel {
      parts.insert("Owner: \(ownerLabel)", at: 1)
    }
    parts.append(expanded)
    return parts.joined(separator: ", ")
  }

  private func lotAccessibilityLabel(
    for lot: CapitalGainSaleLot,
    instrument: Instrument
  ) -> String {
    [
      "Purchased: \(TaxReportPresentation.dateLabel(lot.acquiredDate))",
      "Quantity: \(formattedQuantity(lot.quantity, instrument: instrument))",
      "Cost: \(formattedAmount(lot.costBasis))",
      "Proceeds: \(formattedAmount(lot.proceeds))",
      "Gain: \(formattedAmount(lot.gain))",
      "Holding: \(TaxReportPresentation.holdingPeriodLabel(for: lot.event))",
    ].joined(separator: ", ")
  }

  private func instrumentCell(for sale: CapitalGainSale) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(sale.instrument.displayLabel)
      if let ownerLabel = sale.ownerLabel {
        Text(ownerLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
      } else if sale.instrument.name != sale.instrument.displayLabel {
        Text(sale.instrument.name)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .lineLimit(1)
    .accessibilityElement(children: .combine)
  }

  private func quantityCell(_ quantity: Decimal, instrument: Instrument) -> some View {
    Text(formattedQuantity(quantity, instrument: instrument))
      .monospacedDigit()
      .lineLimit(1)
  }

  private func formattedQuantity(_ quantity: Decimal, instrument: Instrument) -> String {
    switch instrument.kind {
    case .fiatCurrency:
      return InstrumentAmount(quantity: quantity, instrument: instrument).formatted
    case .stock:
      let quantityOnly = QuantityFormatting.formatted(
        kind: instrument.kind,
        quantity: quantity,
        decimals: instrument.decimals,
        displayLabel: instrument.displayLabel,
        currencyCode: nil)
      return "\(quantityOnly) \(instrument.displayLabel)"
    case .cryptoToken:
      return QuantityFormatting.formatted(
        kind: instrument.kind,
        quantity: quantity,
        decimals: instrument.decimals,
        displayLabel: instrument.displayLabel,
        currencyCode: nil)
    }
  }

  private func amountCell(_ quantity: Decimal) -> some View {
    Text(formattedAmount(quantity))
      .monospacedDigit()
      .lineLimit(1)
  }

  private func formattedAmount(_ quantity: Decimal) -> String {
    InstrumentAmount(quantity: quantity, instrument: profileInstrument).formatted
  }

  private func gainLossCell(_ quantity: Decimal) -> some View {
    ReportGainLossText(amount: InstrumentAmount(quantity: quantity, instrument: profileInstrument))
      .lineLimit(1)
  }

  private func lotHeader(_ title: String, width: CGFloat, alignment: Alignment) -> some View {
    Text(title)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .frame(width: width, alignment: alignment)
  }

  private func toggleExpanded(_ id: CapitalGainSaleIdentifier) {
    if expandedSaleIds.contains(id) {
      expandedSaleIds.remove(id)
    } else {
      expandedSaleIds.insert(id)
    }
  }
}

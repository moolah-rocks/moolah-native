import SwiftUI

/// The lightweight positions surface: a title + total header above the
/// responsive positions table. Hosted as the iOS `Positions` tab and the
/// macOS pinned top pane by `PositionsChartTransactionsSplit`.
///
/// Deliberately excludes the chart and performance tiles — those ride at
/// the top of the Chart tab / companion pane so this list stays
/// uncluttered (design §"Where performance + total live").
///
/// `selection` is a binding: tapping a row sets it, filtering the sibling
/// chart pane; the owner clears it on Escape / input change.
struct PositionsPane: View {
  let input: PositionsViewInput
  @Binding var selection: PositionSelection?

  var body: some View {
    VStack(spacing: 0) {
      PositionsHeader(input: input)
      Divider()
      PositionsTable(input: input, selection: $selection)
    }
  }
}

#Preview("Positions pane") {
  PositionsPane(
    input: PositionsViewInput(
      title: "Multi-currency",
      hostCurrency: .AUD,
      positions: [
        ValuedPosition(
          instrument: .USD,
          quantity: 250,
          unitPrice: nil,
          costBasis: nil,
          value: InstrumentAmount(quantity: 380, instrument: .AUD)),
        ValuedPosition(
          instrument: .AUD,
          quantity: 1_000,
          unitPrice: nil,
          costBasis: nil,
          value: InstrumentAmount(quantity: 1_000, instrument: .AUD)),
      ],
      historicalValue: nil),
    selection: .constant(nil)
  )
  .frame(width: 480, height: 320)
}

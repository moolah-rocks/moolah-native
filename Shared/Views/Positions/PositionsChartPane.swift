import SwiftUI

/// The "performance / total header + value chart" group of the account-detail
/// surface. Renders `AccountPerformanceTiles` when the input carries
/// account-level `performance` (investments today; every account type after
/// Increment 3), otherwise the single-row `PositionsHeader` (title + total).
/// Below the header sits `PositionsChart`, or its fixed-footprint loading
/// placeholder while the historical series is still being assembled.
///
/// Hosted at the top of the Chart tab (iOS) / the Chart companion in the
/// resizable bottom pane (macOS) by `PositionsChartTransactionsSplit`, and
/// reused as the top group of `PositionsView` for the investment path.
///
/// `selection` is a binding (not local state) so a position-row tap in a
/// sibling pane filters this chart to that asset. `PositionsChart` reads it;
/// the owner clears it on Escape / input change.
struct PositionsChartPane: View {
  let input: PositionsViewInput
  @Binding var range: PositionsTimeRange
  @Binding var selection: PositionSelection?

  var body: some View {
    VStack(spacing: 0) {
      if let performance = input.performance {
        AccountPerformanceTiles(title: input.title, performance: performance)
      } else {
        PositionsHeader(input: input)
      }
      if input.showsChart {
        Divider()
        PositionsChart(input: input, range: $range, selection: $selection)
          .padding(.vertical, 8)
      } else if input.showsChartLoadingPlaceholder {
        Divider()
        // Matches PositionsChart's footprint (header + 220pt chartBody +
        // rangePicker, plus this container's own vertical padding) so
        // swapping placeholder -> chart doesn't jump the content below it.
        ProgressView()
          .frame(maxWidth: .infinity, minHeight: 280)
          .padding(.vertical, 8)
          .accessibilityLabel("Loading chart")
      }
    }
  }
}

#Preview("Chart pane — with chart") {
  PositionsChartPane(
    input: PositionsViewInput(
      title: "Brokerage",
      hostCurrency: .AUD,
      positions: [
        ValuedPosition(
          instrument: Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP"),
          quantity: 100,
          unitPrice: nil,
          costBasis: InstrumentAmount(quantity: 9_500, instrument: .AUD),
          value: InstrumentAmount(quantity: 10_200, instrument: .AUD))
      ],
      historicalValue: HistoricalValueSeries(
        hostCurrency: .AUD,
        total: (0..<30).map { offset in
          HistoricalValueSeries.Point(
            date: Calendar(identifier: .gregorian)
              .date(byAdding: .day, value: -29 + offset, to: Date()) ?? Date(),
            value: 9_800 + Decimal(offset) * 15,
            cost: 9_500,
            contributions: nil)
        },
        perInstrument: [:])),
    range: .constant(.oneMonth),
    selection: .constant(nil)
  )
  .frame(width: 640, height: 360)
}

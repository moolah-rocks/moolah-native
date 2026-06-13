// swiftlint:disable multiline_arguments
//
// Previews and inline view-builder layouts construct PositionsViewInput
// across multiple lines for readability; the rule fires on every such
// call site in this file.

import SwiftUI

/// Unified container for displaying positions across the app. Composes a
/// header, optional chart, and responsive table from a single
/// `PositionsViewInput`. Renders nothing when `input.rendersNothing` is
/// true (empty input, or a single-instrument holding that matches the
/// host's own instrument, unless the host opts into
/// `alwaysShowsFullSurface`) — callers decide whether to show
/// context-specific empty state.
///
/// Selection: a single tap on a row filters the chart to that instrument.
/// Tapping again, the chip's ✕, or pressing Escape clears the selection.
struct PositionsView: View {
  let input: PositionsViewInput

  @State private var selection: PositionSelection?
  @Binding var range: PositionsTimeRange

  var body: some View {
    if input.rendersNothing {
      EmptyView()
    } else {
      VStack(spacing: 0) {
        if let performance = input.performance {
          AccountPerformanceTiles(title: input.title, performance: performance)
        } else {
          PositionsHeader(input: input)
        }
        if input.showsChart {
          Divider()
          PositionsChart(
            input: input,
            range: $range,
            selection: $selection
          )
          .padding(.vertical, 8)
        }
        Divider()
        PositionsTable(input: input, selection: $selection)
      }
      #if os(macOS)
        .onExitCommand { selection = nil }
      #endif
      .onChange(of: input) { _, _ in
        selection = nil
      }
    }
  }
}

private func defaultPreviewPositions() -> [ValuedPosition] {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let cba = Instrument.stock(ticker: "CBA.AX", exchange: "ASX", name: "CBA")
  let aud = Instrument.AUD
  return [
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
      instrument: aud, quantity: 2_480,
      unitPrice: nil, costBasis: nil,
      value: InstrumentAmount(quantity: 2_480, instrument: aud)),
  ]
}

#Preview("Default") {
  PositionsView(
    input: PositionsViewInput(
      title: "Brokerage",
      hostCurrency: .AUD,
      positions: defaultPreviewPositions(),
      historicalValue: nil  // chart hidden in preview to keep snapshot stable
    ),
    range: .constant(.threeMonths)
  )
  .frame(width: 720, height: 480)
}

#Preview("All fiat") {
  PositionsView(
    input: PositionsViewInput(
      title: "Travel Wallet",
      hostCurrency: .AUD,
      positions: [
        ValuedPosition(
          instrument: .USD, quantity: 100,
          unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 152, instrument: .AUD)),
        ValuedPosition(
          instrument: .AUD, quantity: 1_000,
          unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 1_000, instrument: .AUD)),
      ],
      historicalValue: nil
    ),
    range: .constant(.threeMonths)
  )
  .frame(width: 480, height: 240)
}

#Preview("Conversion failure") {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  PositionsView(
    input: PositionsViewInput(
      title: "Brokerage",
      hostCurrency: .AUD,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 250,
          unitPrice: nil, costBasis: nil, value: nil)
      ],
      historicalValue: nil
    ),
    range: .constant(.threeMonths)
  )
  .frame(width: 480, height: 240)
}

#Preview("Empty") {
  PositionsView(
    input: PositionsViewInput(
      title: "Empty",
      hostCurrency: .AUD,
      positions: [],
      historicalValue: nil
    ),
    range: .constant(.threeMonths)
  )
  .frame(width: 480, height: 200)
}

private func withChartPreviewInput() -> PositionsViewInput {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let aud = Instrument.AUD
  let calendar = Calendar(identifier: .gregorian)
  let now = Date()
  let points: [HistoricalValueSeries.Point] = (0..<60).map { offset in
    let date = calendar.date(byAdding: .day, value: -59 + offset, to: now) ?? now
    return HistoricalValueSeries.Point(
      date: date, value: 10_000 + Decimal(offset) * 25, cost: 9_500,
      contributions: nil)
  }
  let series = HistoricalValueSeries(
    hostCurrency: aud, total: points, perInstrument: [bhp.id: points])
  return PositionsViewInput(
    title: "Brokerage", hostCurrency: aud,
    positions: [
      ValuedPosition(
        instrument: bhp, quantity: 100,
        unitPrice: InstrumentAmount(quantity: (points.last?.value ?? 0) / 100, instrument: aud),
        costBasis: InstrumentAmount(quantity: 9_500, instrument: aud),
        value: InstrumentAmount(quantity: points.last?.value ?? 0, instrument: aud))
    ],
    historicalValue: series)
}

#Preview("With chart") {
  PositionsView(input: withChartPreviewInput(), range: .constant(.threeMonths))
    .frame(width: 720, height: 640)
}

#Preview("With performance tiles") {
  let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  let aud = Instrument.AUD
  return PositionsView(
    input: PositionsViewInput(
      title: "Brokerage",
      hostCurrency: aud,
      positions: [
        ValuedPosition(
          instrument: bhp, quantity: 250,
          unitPrice: InstrumentAmount(quantity: 45.30, instrument: aud),
          costBasis: InstrumentAmount(quantity: 10_125, instrument: aud),
          value: InstrumentAmount(quantity: 11_325, instrument: aud)),
        ValuedPosition(
          instrument: aud, quantity: 2_480,
          unitPrice: nil, costBasis: nil,
          value: InstrumentAmount(quantity: 2_480, instrument: aud)),
      ],
      historicalValue: nil,
      performance: AccountPerformance(
        instrument: aud,
        currentValue: InstrumentAmount(quantity: 13_805, instrument: aud),
        totalContributions: InstrumentAmount(quantity: 12_605, instrument: aud),
        profitLoss: InstrumentAmount(quantity: 1_200, instrument: aud),
        profitLossPercent: Decimal(string: "0.0952"),
        annualisedReturn: Decimal(string: "0.0833"),
        firstFlowDate: Calendar.current.date(byAdding: .year, value: -2, to: Date()))
    ),
    range: .constant(.threeMonths)
  )
  .frame(width: 720, height: 480)
}

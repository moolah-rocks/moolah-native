import Charts
import SwiftUI

enum ChartSeries: String, CaseIterable, Identifiable {
  case availableFunds = "Available Funds"
  case currentFunds = "Current Funds"
  case investedAmount = "Invested Amount"
  case investmentValue = "Investment Value"
  case netWorth = "Net Worth"
  case bestFit = "Best Fit"

  var id: String { rawValue }

  var color: Color {
    switch self {
    case .availableFunds: .chartGreen
    case .currentFunds: .chartOrange
    case .investedAmount: .chartPurple
    case .investmentValue: .chartIndigo
    case .netWorth: .chartBlue
    case .bestFit: .gray
    }
  }

  var enabledByDefault: Bool {
    true
  }
}

struct NetWorthGraphCard: View {
  let balances: [DailyBalance]

  @State private var selectedDate: Date?
  // Internal so the chart-content builders in `+Marks.swift` can read it.
  @State var visibleSeries: Set<ChartSeries> = Set(
    ChartSeries.allCases.filter(\.enabledByDefault))

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text("Net Worth")
          .font(.title2)
          .fontWeight(.semibold)
        if let instrument = balances.first?.balance.instrument {
          Text(instrument.id)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Values in \(instrument.id)")
        }
      }

      if balances.isEmpty {
        emptyState
      } else {
        ExpandableChart(title: "Net Worth") {
          chart
        }
        seriesToggles
      }
    }
    .padding()
    .background(.background)
    .clipShape(.rect(cornerRadius: 12))
  }

  private var emptyState: some View {
    Text("No balance data available")
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .center)
      .frame(height: 300)
  }

  private var chart: some View {
    Chart {
      // Each series gets its own ForEach so Swift Charts properly connects data points.
      // Actual data: solid lines. Forecast data: dashed, lighter lines.
      availableFundsMarks
      currentFundsMarks
      investedAmountMarks
      investmentValueMarks
      netWorthMarks
      bestFitMarks
      if let selectedDate {
        RuleMark(x: .value("Selected", selectedDate))
          .foregroundStyle(.gray.opacity(0.5))
          .lineStyle(StrokeStyle(lineWidth: 1))
      }
    }
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 6)) { _ in
        AxisGridLine()
        AxisTick()
        AxisValueLabel(format: .dateTime.month().day())
      }
    }
    .chartYAxis {
      AxisMarks { value in
        AxisGridLine()
        AxisValueLabel {
          if let amount = value.as(Double.self) {
            Text(
              InstrumentAmount(
                quantity: Decimal(amount), instrument: balances.first?.balance.instrument ?? .AUD
              )
              .formatNoSymbol
            )
            .monospacedDigit()
          }
        }
      }
    }
    .chartXSelection(value: $selectedDate)
    .frame(height: 300)
    .accessibilityLabel(chartAccessibilityLabel)
  }

  /// Summarises the chart's range and current net worth so VoiceOver
  /// gives a useful financial snapshot rather than "Net worth graph".
  /// Empty state is handled by `emptyState` (the chart isn't built when
  /// `balances` is empty), so we can read first / last unconditionally.
  private var chartAccessibilityLabel: String {
    guard let first = actualBalances.first, let last = actualBalances.last else {
      return "Net worth graph"
    }
    let dateFormat: Date.FormatStyle = .dateTime.month(.abbreviated).day().year()
    let rangeText: String
    if first.date == last.date {
      rangeText = first.date.formatted(dateFormat)
    } else {
      rangeText = "\(first.date.formatted(dateFormat)) to \(last.date.formatted(dateFormat))"
    }
    let currentNet = last.netWorth.formatted
    return "Net worth graph from \(rangeText). Current net worth \(currentNet)."
  }

  private var seriesToggles: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 16) {
        ForEach(availableSeries) { series in
          Button {
            if visibleSeries.contains(series) {
              visibleSeries.remove(series)
            } else {
              visibleSeries.insert(series)
            }
          } label: {
            HStack(spacing: 4) {
              if series == .bestFit {
                Rectangle()
                  .stroke(series.color, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
                  .frame(width: 16, height: 2)
              } else {
                Rectangle()
                  .fill(series.color)
                  .frame(width: 16, height: 2)
              }
              Text(series.rawValue)
                .foregroundStyle(visibleSeries.contains(series) ? .primary : .tertiary)
            }
          }
          // `.borderless` (vs `.plain`) preserves keyboard activation
          // on macOS — Space toggles the series instead of being eaten.
          .buttonStyle(.borderless)
          .accessibilityLabel("\(series.rawValue) series")
          .accessibilityAddTraits(visibleSeries.contains(series) ? .isSelected : [])
          .accessibilityHint("Double tap to toggle visibility")
        }
      }
    }
    .font(.caption)
  }

  // Per-series chart-content builders live in `NetWorthGraphCard+Marks.swift`.

  private var availableSeries: [ChartSeries] {
    var series: [ChartSeries] = [.availableFunds, .currentFunds, .netWorth]

    if balances.contains(where: { $0.investments.quantity != 0 }) {
      series.append(.investedAmount)
    }
    if balances.contains(where: { $0.investmentValue != nil }) {
      series.append(.investmentValue)
    }
    if balances.contains(where: { $0.bestFit != nil }) {
      series.append(.bestFit)
    }
    if !forecastBalances.isEmpty {
      // Forecast is implicit — shown when forecast data exists for enabled series
    }
    return series
  }

  // Internal so the per-series builders in `+Marks.swift` can read them.
  var actualBalances: [DailyBalance] {
    balances.filter { !$0.isForecast }
  }

  var forecastBalances: [DailyBalance] {
    balances.filter { $0.isForecast }
  }
}

struct LegendItem: View {
  let color: Color
  let label: String
  var dashed: Bool = false

  var body: some View {
    HStack(spacing: 4) {
      if dashed {
        Rectangle()
          .stroke(color, style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
          .frame(width: 16, height: 2)
      } else {
        Rectangle()
          .fill(color)
          .frame(width: 16, height: 2)
      }
      Text(label)
        .foregroundStyle(.primary)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel(label)
  }
}

#Preview {
  let balances = [
    DailyBalance(
      date: Date().addingTimeInterval(-86400 * 7),
      balance: InstrumentAmount(quantity: 100000, instrument: .AUD),
      earmarked: InstrumentAmount(quantity: 20000, instrument: .AUD),
      investments: InstrumentAmount(quantity: 50000, instrument: .AUD)
    ),
    DailyBalance(
      date: Date().addingTimeInterval(-86400 * 3),
      balance: InstrumentAmount(quantity: 120000, instrument: .AUD),
      earmarked: InstrumentAmount(quantity: 25000, instrument: .AUD),
      investments: InstrumentAmount(quantity: 55000, instrument: .AUD)
    ),
    DailyBalance(
      date: Date(),
      balance: InstrumentAmount(quantity: 110000, instrument: .AUD),
      earmarked: InstrumentAmount(quantity: 22000, instrument: .AUD),
      investments: InstrumentAmount(quantity: 60000, instrument: .AUD)
    ),
  ]

  return NetWorthGraphCard(balances: balances)
    .frame(width: 800)
    .padding()
}

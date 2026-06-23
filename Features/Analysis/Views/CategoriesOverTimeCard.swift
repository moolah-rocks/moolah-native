import Charts
import SwiftUI

struct CategoriesOverTimeCard: View {
  let entries: [CategoryOverTimeEntry]
  let categories: Categories
  let instrument: Instrument
  @Binding var showActualValues: Bool
  var hasUnavailableData: Bool = false

  @State private var selectedDate: Date?

  var body: some View {
    // Derive the colour assignment once per render so the chart's colour
    // scale and the legend swatches resolve identical colours from a single
    // source.
    let colors = CategoryColorAssignment(orderedCategoryIds: entries.map(\.categoryId))
    return VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 8) {
        VStack(alignment: .leading, spacing: 4) {
          Text("Expenses by Category Over Time")
            .font(.title2)
            .fontWeight(.semibold)

          if hasUnavailableData {
            incompleteDataCaption
          }
        }

        Picker("Values", selection: $showActualValues) {
          Text("Percentage").tag(false)
          Text("Actual").tag(true)
        }
        .pickerStyle(.segmented)
        #if os(macOS)
          .frame(width: 200)
        #else
          .frame(maxWidth: 200)
        #endif
        .accessibilityLabel("Toggle between percentage and actual values")
      }

      if entries.isEmpty {
        emptyState
      } else {
        ExpandableChart(title: "Expenses Over Time") {
          chart(colors: colors)
        }
        legend(colors: colors)
      }
    }
    .padding()
    .background(.background)
    .clipShape(.rect(cornerRadius: 12))
  }

  private var incompleteDataCaption: some View {
    Text("Some prices are still loading; totals may be incomplete")
      .font(.caption)
      .foregroundStyle(.secondary)
      .accessibilityLabel("Some prices are still loading; totals may be incomplete")
  }

  private var emptyState: some View {
    Text("No expense data available")
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .center)
      .frame(height: 300)
  }

  private func chart(colors: CategoryColorAssignment) -> some View {
    Chart {
      areaMarks
      if let selectedDate {
        RuleMark(x: .value("Selected", selectedDate))
          .foregroundStyle(.gray.opacity(0.5))
          .lineStyle(StrokeStyle(lineWidth: 1))
      }
    }
    .chartForegroundStyleScale(
      domain: entries.map { categoryLabel(for: $0.categoryId) },
      range: entries.map { colors.color(for: $0.categoryId) }
    )
    .chartXAxis {
      AxisMarks(values: .automatic(desiredCount: 8)) { _ in
        AxisGridLine()
        AxisTick()
        AxisValueLabel(format: .dateTime.month(.abbreviated).year(.twoDigits))
      }
    }
    .chartYAxis {
      AxisMarks { value in
        AxisGridLine()
        AxisValueLabel {
          if let amount = value.as(Double.self) {
            if showActualValues {
              Text(
                InstrumentAmount(quantity: Decimal(amount), instrument: instrument).formatNoSymbol
              )
              .monospacedDigit()
            } else {
              Text("\(Int(amount))%")
                .monospacedDigit()
            }
          }
        }
      }
    }
    .chartXSelection(value: $selectedDate)
    // The legend below already lists each category with its colour swatch
    // and total, so the chart's built-in legend is redundant.
    .chartLegend(.hidden)
    .frame(height: 400)
    .accessibilityLabel(chartAccessibilityLabel)
  }

  @ChartContentBuilder private var areaMarks: some ChartContent {
    ForEach(entries) { entry in
      let name = categoryLabel(for: entry.categoryId)
      ForEach(entry.points) { point in
        AreaMark(
          x: .value("Month", point.monthDate),
          y: .value(
            "Amount",
            showActualValues
              ? Double(truncating: point.actualAmount as NSDecimalNumber) : point.percentage),
          stacking: .standard
        )
        .foregroundStyle(by: .value("Category", name))
      }
    }
  }

  private var chartAccessibilityLabel: String {
    let base =
      "Stacked area chart showing expense categories over time in \(showActualValues ? "actual amounts" : "percentages")"
    guard hasUnavailableData else { return base }
    return base + ". Some months may be incomplete; prices still loading."
  }

  private func legend(colors: CategoryColorAssignment) -> some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 8) {
      ForEach(entries) { entry in
        HStack(spacing: 4) {
          Circle()
            .fill(colors.color(for: entry.categoryId))
            .frame(width: 10, height: 10)
          Text(categoryLabel(for: entry.categoryId))
            .font(.caption)
            .lineLimit(1)
          Spacer()
          Text(InstrumentAmount(quantity: entry.totalAmount, instrument: instrument).formatted)
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
          "\(categoryLabel(for: entry.categoryId)): \(InstrumentAmount(quantity: entry.totalAmount, instrument: instrument).formatted)"
        )
      }
    }
  }

  private func categoryLabel(for id: UUID?) -> String {
    guard let id, let category = categories.by(id: id) else { return "Uncategorized" }
    return categories.path(for: category)
  }
}

#Preview {
  let categories = [
    Category(id: UUID(), name: "Groceries"),
    Category(id: UUID(), name: "Transport"),
    Category(id: UUID(), name: "Entertainment"),
  ]

  let entries = categories.map { category in
    CategoryOverTimeEntry(
      categoryId: category.id,
      points: (0..<6).map { month in
        CategoryOverTimePoint(
          month: "20260\(month + 1)",
          monthDate: Calendar.current.date(
            byAdding: .month, value: -5 + month, to: Date()) ?? Date(),
          actualAmount: Decimal(Int.random(in: 100...500)),
          percentage: Double.random(in: 10...50)
        )
      },
      totalAmount: Decimal(Int.random(in: 600...2000))
    )
  }

  CategoriesOverTimeCard(
    entries: entries,
    categories: Categories(from: categories),
    instrument: .AUD,
    showActualValues: .constant(false)
  )
  .frame(width: 800)
  .padding()
}

#Preview("Incomplete data") {
  let categories = [
    Category(id: UUID(), name: "Groceries"),
    Category(id: UUID(), name: "Transport"),
    Category(id: UUID(), name: "Entertainment"),
  ]

  let entries = categories.map { category in
    CategoryOverTimeEntry(
      categoryId: category.id,
      points: (0..<6).map { month in
        CategoryOverTimePoint(
          month: "20260\(month + 1)",
          monthDate: Calendar.current.date(
            byAdding: .month, value: -5 + month, to: Date()) ?? Date(),
          actualAmount: Decimal(Int.random(in: 100...500)),
          percentage: Double.random(in: 10...50)
        )
      },
      totalAmount: Decimal(Int.random(in: 600...2000))
    )
  }

  CategoriesOverTimeCard(
    entries: entries,
    categories: Categories(from: categories),
    instrument: .AUD,
    showActualValues: .constant(false),
    hasUnavailableData: true
  )
  .frame(width: 800)
  .padding()
}

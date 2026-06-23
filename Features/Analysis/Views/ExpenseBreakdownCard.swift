import Charts
import SwiftUI

struct ExpenseBreakdownCard: View {
  let breakdown: [ExpenseBreakdown]
  let categories: Categories
  var hasUnavailableData: Bool = false

  @State private var selectedCategoryId: UUID?

  var body: some View {
    // Derive the breakdown and its colour assignment once per render so the
    // pie chart's colour scale and the legend swatches resolve identical
    // colours from a single source, and `buildExpenseBreakdown` runs once.
    let breakdown = filteredBreakdown
    let colors = CategoryColorAssignment(orderedCategoryIds: breakdown.map(\.categoryId))
    return VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Expenses by Category")
          .font(.title2)
          .fontWeight(.semibold)

        if hasUnavailableData {
          incompleteDataCaption
        }
      }

      if breakdown.isEmpty {
        emptyState
      } else {
        ExpandableChart(title: "Expenses by Category") {
          pieChart(breakdown, colors: colors)
        }
        legendGrid(breakdown, colors: colors)
        breadcrumbs
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
    Text("No expense data")
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 40)
  }

  private func pieChart(
    _ breakdown: [ExpenseBreakdownWithPercentage], colors: CategoryColorAssignment
  ) -> some View {
    Chart(breakdown, id: \.categoryId) { item in
      SectorMark(
        angle: .value("Amount", Double(truncating: item.totalExpenses.quantity as NSDecimalNumber)),
        innerRadius: .ratio(0.5),
        angularInset: 1.5
      )
      .foregroundStyle(by: .value("Category", categoryLabel(for: item.categoryId)))
      .annotation(position: .overlay) {
        if item.percentage > 5 {
          Text("\(Int(item.percentage))%")
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.white)
            // Black-with-opacity shadow rather than `.primary` so the
            // contrast against pale segments (mint, yellow) holds in
            // both light and dark mode — `.primary` matches the text
            // in dark mode and provides no contrast.
            .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
        }
      }
    }
    // Bind the sector colours to the same assignment legendGrid uses so the
    // two always agree; without an explicit scale Swift Charts paints sectors
    // from its own default palette by data order, which the legend can't match.
    .chartForegroundStyleScale(
      domain: breakdown.map { categoryLabel(for: $0.categoryId) },
      range: breakdown.map { colors.color(for: $0.categoryId) }
    )
    // The legendGrid below already lists each category with its colour
    // swatch and total, so the chart's built-in legend is redundant.
    .chartLegend(.hidden)
    .frame(height: 250)
    .accessibilityLabel(pieChartAccessibilityLabel(breakdown))
  }

  private func legendGrid(
    _ breakdown: [ExpenseBreakdownWithPercentage], colors: CategoryColorAssignment
  ) -> some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 8) {
      ForEach(breakdown, id: \.categoryId) { item in
        legendRow(item, colors: colors)
      }
    }
  }

  /// A legend row is only interactive when the category has children to drill
  /// into; leaf categories render as plain content so VoiceOver doesn't
  /// announce a button that does nothing.
  @ViewBuilder
  private func legendRow(
    _ item: ExpenseBreakdownWithPercentage, colors: CategoryColorAssignment
  ) -> some View {
    let label = categoryLabel(for: item.categoryId)
    let accessibilityLabel = "\(label): \(item.totalExpenses.formatted)"
    if hasChildren(item.categoryId) {
      Button {
        handleCategoryTap(item.categoryId)
      } label: {
        legendRowContent(item, label: label, colors: colors)
      }
      .buttonStyle(.plain)
      .accessibilityLabel(accessibilityLabel)
      .accessibilityHint("Shows subcategories")
    } else {
      legendRowContent(item, label: label, colors: colors)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }
  }

  private func legendRowContent(
    _ item: ExpenseBreakdownWithPercentage, label: String, colors: CategoryColorAssignment
  ) -> some View {
    HStack {
      Circle()
        .fill(colors.color(for: item.categoryId))
        .frame(width: 12, height: 12)
      Text(label)
        .font(.caption)
        .foregroundStyle(.primary)
      Spacer()
      Text(item.totalExpenses.formatted)
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
  }

  private var breadcrumbs: some View {
    Group {
      if selectedCategoryId != nil {
        HStack {
          Button("All Categories") {
            selectedCategoryId = nil
          }
          .font(.caption)
          .foregroundStyle(.tint)
        }
      }
    }
  }

  private var filteredBreakdown: [ExpenseBreakdownWithPercentage] {
    AnalysisStore.buildExpenseBreakdown(
      from: breakdown, categories: categories, selectedCategoryId: selectedCategoryId)
  }

  private func pieChartAccessibilityLabel(_ breakdown: [ExpenseBreakdownWithPercentage]) -> String {
    let base =
      breakdown.count == 1
      ? "Expense breakdown pie chart with 1 category"
      : "Expense breakdown pie chart with \(breakdown.count) categories"
    guard hasUnavailableData else { return base }
    return base + ". Some totals may be incomplete; prices still loading."
  }

  private func categoryLabel(for id: UUID?) -> String {
    guard let id, let category = categories.by(id: id) else { return "Uncategorized" }
    return categories.path(for: category)
  }

  private func hasChildren(_ categoryId: UUID?) -> Bool {
    guard let categoryId else { return false }
    return !categories.children(of: categoryId).isEmpty
  }

  private func handleCategoryTap(_ categoryId: UUID?) {
    if hasChildren(categoryId) {
      selectedCategoryId = categoryId
    }
  }
}

struct ExpenseBreakdownWithPercentage: Identifiable {
  let categoryId: UUID?
  let totalExpenses: InstrumentAmount
  let percentage: Double

  var id: String {
    categoryId?.uuidString ?? "uncategorized"
  }
}

#Preview {
  let categories = [
    Category(id: UUID(), name: "Groceries"),
    Category(id: UUID(), name: "Transport"),
    Category(id: UUID(), name: "Entertainment"),
  ]

  let breakdown = [
    ExpenseBreakdown(
      categoryId: categories[0].id,
      month: "202604",
      totalExpenses: InstrumentAmount(quantity: 450, instrument: .AUD)
    ),
    ExpenseBreakdown(
      categoryId: categories[1].id,
      month: "202604",
      totalExpenses: InstrumentAmount(quantity: 250, instrument: .AUD)
    ),
    ExpenseBreakdown(
      categoryId: categories[2].id,
      month: "202604",
      totalExpenses: InstrumentAmount(quantity: 150, instrument: .AUD)
    ),
  ]

  ExpenseBreakdownCard(breakdown: breakdown, categories: Categories(from: categories))
    .frame(width: 400)
    .padding()
}

#Preview("Incomplete data") {
  let categories = [
    Category(id: UUID(), name: "Groceries"),
    Category(id: UUID(), name: "Transport"),
  ]

  let breakdown = [
    ExpenseBreakdown(
      categoryId: categories[0].id,
      month: "202604",
      totalExpenses: InstrumentAmount(quantity: 450, instrument: .AUD)
    ),
    ExpenseBreakdown(
      categoryId: categories[1].id,
      month: "202604",
      totalExpenses: InstrumentAmount(quantity: 250, instrument: .AUD)
    ),
  ]

  ExpenseBreakdownCard(
    breakdown: breakdown,
    categories: Categories(from: categories),
    hasUnavailableData: true
  )
  .frame(width: 400)
  .padding()
}

#Preview("Many categories (palette + grey tail)") {
  let names = [
    "Housing", "Groceries", "Transport", "Dining", "Utilities", "Health",
    "Shopping", "Entertainment", "Insurance", "Subscriptions", "Travel",
    "Education", "Gifts", "Pets",
  ]
  let categories = names.map { Category(id: UUID(), name: $0) }
  let breakdown = categories.enumerated().map { index, category in
    ExpenseBreakdown(
      categoryId: category.id,
      month: "202604",
      totalExpenses: InstrumentAmount(quantity: Decimal(1500 - index * 100), instrument: .AUD)
    )
  }

  ScrollView {
    ExpenseBreakdownCard(breakdown: breakdown, categories: Categories(from: categories))
      .frame(width: 400)
      .padding()
  }
}

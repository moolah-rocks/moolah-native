import SwiftUI

struct IncomeExpenseTableCard: View {
  let data: [MonthlyIncomeExpense]

  private static let initialVisibleCount = 6
  private static let loadMoreCount = 6

  @State private var includeEarmarks = false
  @State private var visibleCount = IncomeExpenseTableCard.initialVisibleCount

  @ScaledMetric private var monthColumnMinWidth: CGFloat = 120
  @ScaledMetric private var amountColumnMinWidth: CGFloat = 100
  @ScaledMetric private var totalColumnMinWidth: CGFloat = 110

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Monthly Income & Expense")
          .font(.title2)
          .fontWeight(.semibold)

        Toggle("Include Earmarks", isOn: $includeEarmarks)
          .toggleStyle(.switch)
          .font(.caption)
          .fixedSize()
      }

      if data.isEmpty {
        emptyState
      } else {
        tableView
      }
    }
    .padding()
    .background(.background)
    .clipShape(.rect(cornerRadius: 12))
    .onChange(of: data.count) { _, _ in
      visibleCount = Self.initialVisibleCount
    }
  }

  private var emptyState: some View {
    Text("No income/expense data")
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .center)
      .padding(.vertical, 40)
  }

  private var visibleData: [MonthlyIncomeExpense] {
    Array(data.prefix(visibleCount))
  }

  private var tableView: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      VStack(spacing: 0) {
        headerRow
        Divider()
        dataRows
      }
      .frame(minWidth: 530)
    }
    .accessibilityLabel("Monthly income and expense table")
  }

  private var headerRow: some View {
    HStack(spacing: 12) {
      Text("Month").frame(minWidth: monthColumnMinWidth, alignment: .leading)
      Text("Income").frame(minWidth: amountColumnMinWidth, alignment: .trailing)
      Text("Expense").frame(minWidth: amountColumnMinWidth, alignment: .trailing)
      Text("Savings").frame(minWidth: amountColumnMinWidth, alignment: .trailing)
      Text("Total Savings").frame(minWidth: totalColumnMinWidth, alignment: .trailing)
    }
    .font(.caption)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private var dataRows: some View {
    // Lazy, participates in outer ScrollView.
    LazyVStack(spacing: 0) {
      ForEach(visibleData) { item in
        dataRow(for: item)
      }
    }
  }

  private func dataRow(for item: MonthlyIncomeExpense) -> some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(Self.monthLabel(for: item))
            .font(.body)
            .monospacedDigit()
          Text(monthsAgoLabel(for: item))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .frame(minWidth: monthColumnMinWidth, alignment: .leading)
        amountColumns(for: item)
        cumulativeCell(for: item)
          .frame(minWidth: totalColumnMinWidth, alignment: .trailing)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        Self.accessibilityLabel(for: item, in: data, includeEarmarks: includeEarmarks))
      Divider()
    }
    .onAppear {
      if item.id == visibleData.last?.id, visibleCount < data.count {
        visibleCount += Self.loadMoreCount
      }
    }
  }

  /// Income, expense, and savings columns. When the month's prices are still
  /// loading every column shows the unavailable placeholder.
  @ViewBuilder
  private func amountColumns(for item: MonthlyIncomeExpense) -> some View {
    if item.hasUnavailableData {
      ForEach(0..<3, id: \.self) { _ in
        unavailableCell.frame(minWidth: amountColumnMinWidth, alignment: .trailing)
      }
    } else {
      InstrumentAmountView(amount: income(for: item))
        .frame(minWidth: amountColumnMinWidth, alignment: .trailing)
      InstrumentAmountView(amount: expense(for: item))
        .frame(minWidth: amountColumnMinWidth, alignment: .trailing)
      InstrumentAmountView(amount: profit(for: item))
        .frame(minWidth: amountColumnMinWidth, alignment: .trailing)
    }
  }

  /// Placeholder shown in an amount column when a month's prices are still
  /// loading and the value can't be computed.
  private var unavailableCell: some View {
    Text(verbatim: "—")
      .foregroundStyle(.secondary)
  }

  @ViewBuilder
  private func cumulativeCell(for item: MonthlyIncomeExpense) -> some View {
    if let cumulative = cumulativeSavingsValue(for: item) {
      InstrumentAmountView(amount: cumulative)
    } else {
      unavailableCell
    }
  }

  private func income(for item: MonthlyIncomeExpense) -> InstrumentAmount {
    includeEarmarks ? item.totalIncome : item.income
  }

  private func expense(for item: MonthlyIncomeExpense) -> InstrumentAmount {
    includeEarmarks ? item.totalExpense : item.expense
  }

  private func profit(for item: MonthlyIncomeExpense) -> InstrumentAmount {
    includeEarmarks ? item.totalProfit : item.profit
  }

  private func cumulativeSavingsValue(for item: MonthlyIncomeExpense) -> InstrumentAmount? {
    guard let index = data.firstIndex(where: { $0.id == item.id }) else { return nil }
    return Self.cumulativeSavingsColumn(in: data, includeEarmarks: includeEarmarks)[index]
  }

  /// Cumulative savings from the first row through the given item.
  /// Data is sorted most-recent-first, so the first row's total equals its own
  /// savings and each subsequent row adds to the running total.
  nonisolated static func cumulativeSavings(
    upTo item: MonthlyIncomeExpense,
    in data: [MonthlyIncomeExpense],
    includeEarmarks: Bool
  ) -> InstrumentAmount {
    guard let index = data.firstIndex(where: { $0.id == item.id }) else {
      return .zero(instrument: data.first?.income.instrument ?? .AUD)
    }
    let zero = InstrumentAmount.zero(instrument: item.income.instrument)
    return data[...index].reduce(zero) { total, month in
      total + (includeEarmarks ? month.totalProfit : month.profit)
    }
  }

  /// Running cumulative savings aligned 1:1 with `data` (most-recent-first).
  ///
  /// Once a month has `hasUnavailableData == true`, the running total depends on
  /// an unknown value, so that month's cumulative — and every later month's —
  /// is `nil` (unavailable). Months before the first unavailable month keep
  /// their real running total.
  nonisolated static func cumulativeSavingsColumn(
    in data: [MonthlyIncomeExpense],
    includeEarmarks: Bool
  ) -> [InstrumentAmount?] {
    let instrument = data.first?.income.instrument ?? .AUD
    var running = InstrumentAmount.zero(instrument: instrument)
    var unavailableReached = false
    var column: [InstrumentAmount?] = []
    column.reserveCapacity(data.count)
    for month in data {
      if month.hasUnavailableData { unavailableReached = true }
      if unavailableReached {
        column.append(nil)
      } else {
        running += includeEarmarks ? month.totalProfit : month.profit
        column.append(running)
      }
    }
    return column
  }

  /// Builds a single combined VoiceOver label for a data row, so VoiceOver reads
  /// the row as one element (`month: income, expense, savings, total savings`)
  /// rather than traversing each `InstrumentAmountView` independently.
  nonisolated static func accessibilityLabel(
    for item: MonthlyIncomeExpense,
    in data: [MonthlyIncomeExpense],
    includeEarmarks: Bool
  ) -> String {
    let month = Self.monthLabel(for: item)
    if item.hasUnavailableData {
      return "\(month): data unavailable, prices still loading"
    }
    let income = includeEarmarks ? item.totalIncome : item.income
    let expense = includeEarmarks ? item.totalExpense : item.expense
    let profit = includeEarmarks ? item.totalProfit : item.profit
    let total = Self.cumulativeSavings(upTo: item, in: data, includeEarmarks: includeEarmarks)
    return
      "\(month). Income \(income.formatted). Expense \(expense.formatted). Savings \(profit.formatted). Total savings \(total.formatted)."
  }

  nonisolated static func monthLabel(for item: MonthlyIncomeExpense) -> String {
    item.start.formatted(.dateTime.month(.abbreviated).year())
  }

  private func monthsAgoLabel(for item: MonthlyIncomeExpense) -> String {
    let months = Calendar.current.dateComponents([.month], from: item.end, to: Date()).month ?? 0
    if months == 0 { return "This month" }
    if months == 1 { return "Last month" }
    return "\(months) months ago"
  }
}

private enum IncomeExpenseTableCardPreviewData {
  private static func aud(_ value: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: value, instrument: .AUD)
  }

  private static func month(
    _ key: String,
    days: ClosedRange<Int>,
    plain: (income: Decimal, expense: Decimal),
    earmarked: (income: Decimal, expense: Decimal) = (0, 0),
    hasUnavailableData: Bool = false
  ) -> MonthlyIncomeExpense {
    MonthlyIncomeExpense(
      month: key,
      start: Date().addingTimeInterval(-86400 * Double(days.upperBound)),
      end: Date().addingTimeInterval(-86400 * Double(days.lowerBound)),
      income: aud(plain.income),
      expense: aud(plain.expense),
      profit: aud(plain.income - plain.expense),
      earmarkedIncome: aud(earmarked.income),
      earmarkedExpense: aud(earmarked.expense),
      earmarkedProfit: aud(earmarked.income - earmarked.expense),
      hasUnavailableData: hasUnavailableData)
  }

  static let sample: [MonthlyIncomeExpense] = [
    month("202604", days: 0...30, plain: (5000, 3000), earmarked: (500, 200)),
    month("202603", days: 31...60, plain: (4800, 3200), earmarked: (400, 250)),
    month("202602", days: 61...90, plain: (0, 0), hasUnavailableData: true),
  ]
}

#Preview {
  IncomeExpenseTableCard(data: IncomeExpenseTableCardPreviewData.sample)
    .frame(width: 600, height: 500)
    .padding()
}

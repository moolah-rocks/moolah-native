import SwiftUI

struct IncomeExpenseTableCard: View {
  let data: [MonthlyIncomeExpense]

  private static let initialVisibleCount = 6
  private static let loadMoreCount = 6

  @State private var includeInvestments = true
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

        Toggle("Include Investments", isOn: $includeInvestments)
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
          HStack(spacing: 4) {
            Text(Self.monthLabel(for: item))
              .font(.body)
              .monospacedDigit()
            if item.hasUnavailableData {
              // Visual hint that the row's prices are still loading. The row's
              // combined a11y label already announces this, so hide it here.
              Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
          }
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
        Self.accessibilityLabel(for: item, in: data, includeInvestments: includeInvestments))
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
      .monospacedDigit()
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
    includeInvestments ? item.totalIncome : item.income
  }

  private func expense(for item: MonthlyIncomeExpense) -> InstrumentAmount {
    includeInvestments ? item.totalExpense : item.expense
  }

  private func profit(for item: MonthlyIncomeExpense) -> InstrumentAmount {
    includeInvestments ? item.totalProfit : item.profit
  }

  private func cumulativeSavingsValue(for item: MonthlyIncomeExpense) -> InstrumentAmount? {
    guard let index = data.firstIndex(where: { $0.id == item.id }) else { return nil }
    return Self.cumulativeSavingsColumn(in: data, includeInvestments: includeInvestments)[index]
  }

  /// Running cumulative savings aligned 1:1 with `data` (most-recent-first).
  ///
  /// Once a month has `hasUnavailableData == true`, the running total depends on
  /// an unknown value, so that month's cumulative — and every later month's —
  /// is `nil` (unavailable). Months before the first unavailable month keep
  /// their real running total.
  nonisolated static func cumulativeSavingsColumn(
    in data: [MonthlyIncomeExpense],
    includeInvestments: Bool
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
        running += includeInvestments ? month.totalProfit : month.profit
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
    includeInvestments: Bool
  ) -> String {
    let month = Self.monthLabel(for: item)
    if item.hasUnavailableData {
      return "\(month): data unavailable, prices still loading"
    }
    let income = includeInvestments ? item.totalIncome : item.income
    let expense = includeInvestments ? item.totalExpense : item.expense
    let profit = includeInvestments ? item.totalProfit : item.profit
    let base =
      "\(month). Income \(income.formatted). Expense \(expense.formatted). Savings \(profit.formatted)."
    // The cumulative column is nil-from-the-first-unavailable-month, so an
    // available row that follows an unavailable one has no real running total.
    // Announce that rather than the misleading number a plain reduce would give.
    let index = data.firstIndex { $0.id == item.id }
    let column = Self.cumulativeSavingsColumn(in: data, includeInvestments: includeInvestments)
    guard let index, let total = column[index] else {
      return base + " Total savings unavailable."
    }
    return base + " Total savings \(total.formatted)."
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
    base: (income: Decimal, expense: Decimal),
    investments: (income: Decimal, expense: Decimal) = (0, 0),
    hasUnavailableData: Bool = false
  ) -> MonthlyIncomeExpense {
    MonthlyIncomeExpense(
      month: key,
      start: Date().addingTimeInterval(-86400 * Double(days.upperBound)),
      end: Date().addingTimeInterval(-86400 * Double(days.lowerBound)),
      income: aud(base.income),
      expense: aud(base.expense),
      profit: aud(base.income - base.expense),
      investmentIncome: aud(investments.income),
      investmentExpense: aud(investments.expense),
      investmentProfit: aud(investments.income - investments.expense),
      hasUnavailableData: hasUnavailableData)
  }

  static let sample: [MonthlyIncomeExpense] = [
    month("202604", days: 0...30, base: (5000, 3000), investments: (500, 200)),
    month("202603", days: 31...60, base: (4800, 3200), investments: (400, 250)),
    month("202602", days: 61...90, base: (0, 0), hasUnavailableData: true),
  ]
}

#Preview("Mixed — includes unavailable month") {
  IncomeExpenseTableCard(data: IncomeExpenseTableCardPreviewData.sample)
    .frame(width: 600, height: 500)
    .padding()
}

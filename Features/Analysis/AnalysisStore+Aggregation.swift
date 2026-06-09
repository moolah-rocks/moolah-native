import Foundation

// Category-rollup aggregations for `AnalysisStore`: the chart-ready
// "categories over time" series and the pie-chart expense breakdown.
// Split out of the core store so the main file stays under the
// file-length budget and the pure (static, testable) transforms sit
// together. See issue #1075.
extension AnalysisStore {

  /// Transforms expense breakdown into chart-ready data grouped by root-level category and month.
  func categoriesOverTime(categories: Categories) -> [CategoryOverTimeEntry] {
    Self.buildCategoriesOverTime(from: displayedExpenseBreakdown, categories: categories)
  }

  /// Pure function for testability: transforms expense breakdown into chart-ready grouped data.
  /// Each category's expenses are rolled up to the root level, then sorted by total descending.
  static func buildCategoriesOverTime(
    from breakdown: [ExpenseBreakdown], categories: Categories
  ) -> [CategoryOverTimeEntry] {
    var rootTotals: [UUID?: [String: Decimal]] = [:]
    var allMonths: Set<String> = []

    // Negate totalExpenses (server returns negative for expenses) and clamp to zero,
    // matching the web app's categoryOverTimeData.js approach.
    for item in breakdown {
      // A row whose month couldn't be priced is a convertible subset of a mixed
      // total — summing it into the projection would understate the chart, so
      // exclude it. The window-level caption (driven by the store) signals it.
      guard !item.hasUnavailableData else { continue }
      let rootId = rootCategoryId(for: item.categoryId, categories: categories)
      allMonths.insert(item.month)
      rootTotals[rootId, default: [:]][item.month, default: 0] += -item.totalExpenses.quantity
    }

    let orderedMonths = allMonths.sorted()

    var monthTotals: [String: Decimal] = [:]
    for (_, months) in rootTotals {
      for (month, amount) in months {
        monthTotals[month, default: 0] += max(0, amount)
      }
    }

    return rootTotals.map { categoryId, months in
      let points = orderedMonths.map { month -> CategoryOverTimePoint in
        let amount = max(0, months[month] ?? 0)
        let total = monthTotals[month] ?? 1
        let percentage =
          total > 0 ? Double(truncating: (amount / total * 100) as NSDecimalNumber) : 0
        return CategoryOverTimePoint(
          month: month,
          monthDate: parseMonth(month),
          actualAmount: amount,
          percentage: percentage
        )
      }
      let totalAmount = months.values.reduce(Decimal(0), +)
      return CategoryOverTimeEntry(
        categoryId: categoryId,
        points: points,
        totalAmount: totalAmount
      )
    }
    .sorted { $0.totalAmount > $1.totalAmount }
  }

  private static func rootCategoryId(for categoryId: UUID?, categories: Categories) -> UUID? {
    guard var id = categoryId else { return nil }
    while let category = categories.by(id: id), let parentId = category.parentId {
      id = parentId
    }
    return id
  }

  /// Builds the pie-chart breakdown shown in `ExpenseBreakdownCard`.
  ///
  /// At the top level (`selectedCategoryId == nil`), each root category's total rolls up all
  /// descendants' expenses. When drilled into a parent, each direct child's total rolls up its
  /// own subtree; transactions directly on the drilled-into parent, or outside its subtree, are
  /// excluded.
  static func buildExpenseBreakdown(
    from breakdown: [ExpenseBreakdown],
    categories: Categories,
    selectedCategoryId: UUID?
  ) -> [ExpenseBreakdownWithPercentage] {
    guard let instrument = breakdown.first?.totalExpenses.instrument else { return [] }

    var totals: [UUID?: Decimal] = [:]
    for item in breakdown {
      // Skip rows whose month couldn't be priced: their surviving value is a
      // convertible subset of a mixed total, so summing it would understate the
      // pie. The window-level caption (driven by the store) signals it instead.
      guard !item.hasUnavailableData else { continue }
      let targetId: UUID?
      if let selected = selectedCategoryId {
        guard
          let child = childOfAncestor(
            for: item.categoryId, ancestor: selected, categories: categories)
        else { continue }
        targetId = child
      } else {
        targetId = rootCategoryId(for: item.categoryId, categories: categories)
      }
      totals[targetId, default: 0] += -item.totalExpenses.quantity
    }

    let grandTotal = totals.values.reduce(Decimal(0)) { $0 + max(0, $1) }

    return
      totals
      .map { id, amount -> ExpenseBreakdownWithPercentage in
        let clamped = max(0, amount)
        let percentage =
          grandTotal > 0
          ? Double(truncating: (clamped / grandTotal * 100) as NSDecimalNumber) : 0
        return ExpenseBreakdownWithPercentage(
          categoryId: id,
          totalExpenses: InstrumentAmount(quantity: clamped, instrument: instrument),
          percentage: percentage
        )
      }
      .sorted { $0.totalExpenses.quantity > $1.totalExpenses.quantity }
  }

  /// Returns the id of the node in `ancestor`'s direct children that is an ancestor of (or equal
  /// to) `categoryId`, or nil if `categoryId` is outside `ancestor`'s subtree or is `ancestor`
  /// itself.
  private static func childOfAncestor(
    for categoryId: UUID?, ancestor: UUID, categories: Categories
  ) -> UUID? {
    guard var id = categoryId else { return nil }
    while let category = categories.by(id: id) {
      if category.parentId == ancestor {
        return id
      }
      guard let parentId = category.parentId else { return nil }
      id = parentId
    }
    return nil
  }

  private static func parseMonth(_ month: String) -> Date {
    FinancialMonth.date(forKey: month) ?? Date.distantPast
  }
}

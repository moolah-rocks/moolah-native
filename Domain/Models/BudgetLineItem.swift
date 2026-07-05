import Foundation

struct BudgetLineItem: Identifiable, Sendable {
  let id: UUID
  let categoryPath: String
  let actual: InstrumentAmount
  let budgeted: InstrumentAmount

  var remaining: InstrumentAmount { budgeted + actual }

  /// Stable identifier for the synthesized "Uncategorised" row `buildLineItems` appends
  /// when uncategorised spend is present. Category ids are random `UUID()`s (see
  /// `Category.init`), so this well-known constant can never collide with a real
  /// category id. Built from the raw byte tuple (rather than the failable
  /// `UUID(uuidString:)`) so the constant needs no force unwrap.
  static let uncategorisedId = UUID(
    uuid: (
      0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01
    ))

  /// Merges budget items with category expense balances into a sorted list of line items.
  ///
  /// All amounts must be expressed in `earmarkInstrument`. `buildLineItems` enforces
  /// this by coercing budget items and category balances onto the earmark's instrument,
  /// which is the required common denominator for sums across the list (see
  /// `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 1/2).
  ///
  /// `uncategorised`, when non-nil, becomes a single "Uncategorised" line item
  /// (`budgeted = 0`, `actual = uncategorised`) pinned **after** the sorted category
  /// rows — matching the Reports screen's pinned-bottom treatment of the same total
  /// (see `CategoryBalanceTable`). It is NOT folded into `unallocatedAmount`, which is
  /// a budget-side figure (`savingsGoal − sum(allocations)`), not a spend total. `nil`
  /// omits the row entirely (no uncategorised legs in range).
  static func buildLineItems(
    budgetItems: [EarmarkBudgetItem],
    categoryBalances: [UUID: InstrumentAmount],
    categories: Categories,
    earmarkInstrument: Instrument,
    uncategorised: InstrumentAmount? = nil
  ) -> [BudgetLineItem] {
    var seen = Set<UUID>()
    var result: [BudgetLineItem] = []
    let zero = InstrumentAmount.zero(instrument: earmarkInstrument)

    // Add all budgeted categories
    for item in budgetItems {
      seen.insert(item.categoryId)
      let path = categories.by(id: item.categoryId).map { categories.path(for: $0) } ?? "Unknown"
      let budgeted = item.inInstrument(earmarkInstrument).amount
      let actual = categoryBalances[item.categoryId] ?? zero
      result.append(
        BudgetLineItem(
          id: item.categoryId,
          categoryPath: path,
          actual: actual,
          budgeted: budgeted
        ))
    }

    // Add categories with spending but no budget
    for (categoryId, actual) in categoryBalances where !seen.contains(categoryId) {
      let path = categories.by(id: categoryId).map { categories.path(for: $0) } ?? "Unknown"
      result.append(
        BudgetLineItem(
          id: categoryId,
          categoryPath: path,
          actual: actual,
          budgeted: zero
        ))
    }

    var sorted = result.sorted { $0.categoryPath < $1.categoryPath }

    if let uncategorised {
      let actual =
        uncategorised.instrument == earmarkInstrument
        ? uncategorised
        : InstrumentAmount(quantity: uncategorised.quantity, instrument: earmarkInstrument)
      sorted.append(
        BudgetLineItem(
          id: uncategorisedId,
          categoryPath: "Uncategorised",
          actual: actual,
          budgeted: zero
        ))
    }

    return sorted
  }

  /// Calculates the unallocated portion of a savings goal.
  /// Returns nil if there is no savings goal.
  ///
  /// `Earmark.init` guarantees `savingsGoal.instrument == earmark.instrument`, and every
  /// `EarmarkBudgetItem` is stored in the earmark's instrument. Those invariants keep the
  /// reduction below instrument-safe (see `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 1/2).
  static func unallocatedAmount(
    budgetItems: [EarmarkBudgetItem],
    savingsGoal: InstrumentAmount?
  ) -> InstrumentAmount? {
    guard let goal = savingsGoal, goal.isPositive else { return nil }
    let totalBudget =
      budgetItems
      .map { $0.inInstrument(goal.instrument).amount }
      .reduce(InstrumentAmount.zero(instrument: goal.instrument)) { $0 + $1 }
    return goal - totalBudget
  }
}

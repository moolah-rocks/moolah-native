import Foundation
import Testing

@testable import Moolah

// MARK: - BudgetLineItem Uncategorised Row
//
// Split from `BudgetLineItemMergeTests` to keep both suites under the
// `type_body_length` / `file_length` thresholds (see
// `reference_insight_chart_test_file_splitting.md`: stack each new builder's
// tests in their own `@Suite` file).

@Suite("BudgetLineItem Uncategorised Row")
struct BudgetLineItemUncategorisedTests {
  @Test
  func buildLineItemsOmitsUncategorisedRowWhenNil() {
    let catId = UUID()
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])
    let budgetItems = [
      EarmarkBudgetItem(
        categoryId: catId,
        amount: InstrumentAmount(quantity: Decimal(100), instrument: .defaultTestInstrument))
    ]

    let result = BudgetLineItem.buildLineItems(
      budgetItems: budgetItems,
      categoryBalances: [:],
      categories: categories,
      earmarkInstrument: .defaultTestInstrument,
      uncategorised: nil
    )

    #expect(result.count == 1)
    #expect(!result.contains { $0.id == BudgetLineItem.uncategorisedId })
  }

  @Test
  func buildLineItemsAppendsUncategorisedRowWithZeroBudget() {
    let uncategorisedSpend = InstrumentAmount(
      quantity: Decimal(-15000) / 100, instrument: Instrument.defaultTestInstrument)

    let result = BudgetLineItem.buildLineItems(
      budgetItems: [],
      categoryBalances: [:],
      categories: Categories(from: []),
      earmarkInstrument: .defaultTestInstrument,
      uncategorised: uncategorisedSpend
    )

    #expect(result.count == 1)
    let row = result.first { $0.id == BudgetLineItem.uncategorisedId }
    #expect(row != nil)
    #expect(row?.categoryPath == "Uncategorised")
    #expect(row?.budgeted.quantity == Decimal(0))
    #expect(row?.budgeted.instrument == .defaultTestInstrument)
    #expect(row?.actual.quantity == Decimal(-15000) / 100)
  }

  @Test
  func buildLineItemsPinsUncategorisedRowLastAfterAlphabeticalSort() {
    let cat1 = Category(id: UUID(), name: "Alpha")
    let cat2 = Category(id: UUID(), name: "Zebra")
    let categories = Categories(from: [cat1, cat2])
    let categoryBalances: [UUID: InstrumentAmount] = [
      cat1.id: InstrumentAmount(quantity: Decimal(-10), instrument: .defaultTestInstrument),
      cat2.id: InstrumentAmount(quantity: Decimal(-20), instrument: .defaultTestInstrument),
    ]
    let uncategorisedSpend = InstrumentAmount(
      quantity: Decimal(-5), instrument: .defaultTestInstrument)

    let result = BudgetLineItem.buildLineItems(
      budgetItems: [],
      categoryBalances: categoryBalances,
      categories: categories,
      earmarkInstrument: .defaultTestInstrument,
      uncategorised: uncategorisedSpend
    )

    // "Uncategorised" would sort between "Alpha" and "Zebra" alphabetically;
    // it must instead be pinned last, matching the Reports pinned-bottom treatment.
    #expect(result.map(\.categoryPath) == ["Alpha", "Zebra", "Uncategorised"])
    #expect(result.last?.id == BudgetLineItem.uncategorisedId)
  }

  @Test
  func buildLineItemsCoercesUncategorisedToEarmarkInstrument() {
    // A mismatched instrument label (defensive — the caller is expected to fetch
    // with `targetInstrument: earmark.instrument` already) is re-expressed onto
    // the earmark's instrument so sums across the list stay instrument-safe.
    let uncategorisedSpend = InstrumentAmount(quantity: Decimal(-42), instrument: .USD)

    let result = BudgetLineItem.buildLineItems(
      budgetItems: [],
      categoryBalances: [:],
      categories: Categories(from: []),
      earmarkInstrument: .AUD,
      uncategorised: uncategorisedSpend
    )

    #expect(result.count == 1)
    #expect(result.first?.actual.instrument == .AUD)
    #expect(result.first?.actual.quantity == Decimal(-42))
  }

  @Test
  func totalActualReductionIncludesUncategorisedRow() {
    let catId = UUID()
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])
    let budgetItems = [
      EarmarkBudgetItem(
        categoryId: catId,
        amount: InstrumentAmount(quantity: Decimal(100), instrument: .defaultTestInstrument))
    ]
    let categoryBalances: [UUID: InstrumentAmount] = [
      catId: InstrumentAmount(quantity: Decimal(-30), instrument: .defaultTestInstrument)
    ]
    let uncategorisedSpend = InstrumentAmount(
      quantity: Decimal(-15), instrument: .defaultTestInstrument)

    let result = BudgetLineItem.buildLineItems(
      budgetItems: budgetItems,
      categoryBalances: categoryBalances,
      categories: categories,
      earmarkInstrument: .defaultTestInstrument,
      uncategorised: uncategorisedSpend
    )

    let totalActual = result.reduce(InstrumentAmount.zero(instrument: .defaultTestInstrument)) {
      $0 + $1.actual
    }
    // -30 (Groceries) + -15 (Uncategorised) = -45
    #expect(totalActual.quantity == Decimal(-45))
  }
}

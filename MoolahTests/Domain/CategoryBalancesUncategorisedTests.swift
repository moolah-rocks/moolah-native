import Foundation
import Testing

@testable import Moolah

/// Contract tests for `CategoryBalances.uncategorised` — the combined-query
/// counterpart of `AnalysisCategoryBalancesTests`. Split into its own file
/// per `guides/CODE_GUIDE.md` file-length discipline (mirrors the existing
/// per-builder test-file split used elsewhere in this suite).
///
/// A single `fetchCategoryBalances` SQL aggregation has NO `category_id IS
/// NOT NULL` filter: null-category rows route to `uncategorised`, non-null
/// rows to `byCategory`. `byCategory` still excludes uncategorised legs —
/// unconditionally, regardless of whether any uncategorised legs exist in
/// range (`categoryBalancesByCategoryUnaffectedByUncategorised` pins that
/// independence). See
/// `plans/2026-07-05-reports-uncategorised-row-plan.md`, "Design (revised —
/// single combined query)".
@Suite("AnalysisRepository Contract Tests — Category Balances Uncategorised")
struct CategoryBalancesUncategorisedTests {

  @Test("fetchCategoryBalances routes categoryless legs to uncategorised, not byCategory")
  func categoryBalancesRequiresCategory() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Test Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let cat = Category(id: UUID(), name: "Misc")
    _ = try await backend.categories.create(cat)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    let dateRange = today...today

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .expense, categoryId: cat.id)
        ]))

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Uncategorized",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -30, type: .expense)
        ]))

    let result = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange, transactionType: .expense,
      filters: nil, targetInstrument: .defaultTestInstrument)

    // The categoryless leg is excluded from `byCategory`...
    #expect(result.byCategory.count == 1)
    #expect(
      result.byCategory[cat.id]
        == InstrumentAmount(quantity: -50, instrument: .defaultTestInstrument))
    // ...and appears in `uncategorised` instead.
    #expect(
      result.uncategorised
        == InstrumentAmount(quantity: -30, instrument: .defaultTestInstrument))
  }

  @Test("fetchCategoryBalances uncategorised is nil when there are no categoryless legs")
  func categoryBalancesNoUncategorisedIsNil() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Test Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let cat = Category(id: UUID(), name: "Misc")
    _ = try await backend.categories.create(cat)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    let dateRange = today...today

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .expense, categoryId: cat.id)
        ]))

    let result = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange, transactionType: .expense,
      filters: nil, targetInstrument: .defaultTestInstrument)

    #expect(result.uncategorised == nil)
  }

  @Test("fetchCategoryBalances byCategory totals are unaffected by uncategorised legs")
  func categoryBalancesByCategoryUnaffectedByUncategorised() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Test Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let cat1 = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(cat1)
    let cat2 = Category(id: UUID(), name: "Restaurants")
    _ = try await backend.categories.create(cat2)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    let dateRange = today...today

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .expense, categoryId: cat1.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Restaurant",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -30, type: .expense, categoryId: cat2.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Uncategorized",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -999, type: .expense)
        ]))

    let result = try await backend.analysis.fetchCategoryBalances(
      dateRange: dateRange, transactionType: .expense,
      filters: nil, targetInstrument: .defaultTestInstrument)

    #expect(result.byCategory.count == 2)
    #expect(
      result.byCategory[cat1.id]
        == InstrumentAmount(quantity: -50, instrument: .defaultTestInstrument))
    #expect(
      result.byCategory[cat2.id]
        == InstrumentAmount(quantity: -30, instrument: .defaultTestInstrument))
    #expect(
      result.uncategorised
        == InstrumentAmount(quantity: -999, instrument: .defaultTestInstrument))
  }
}

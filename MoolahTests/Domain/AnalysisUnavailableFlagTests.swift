import Foundation
import Testing

@testable import Moolah

@Suite("AnalysisUnavailableFlag Tests")
struct AnalysisUnavailableFlagTests {

  // MARK: - MonthlyIncomeExpense

  @Test("MonthlyIncomeExpense defaults hasUnavailableData to false when omitted")
  func monthlyIncomeExpenseDefaultsFalse() {
    let item = MonthlyIncomeExpense(
      month: "202601",
      start: Date(),
      end: Date(),
      income: .zero(instrument: .defaultTestInstrument),
      expense: .zero(instrument: .defaultTestInstrument),
      profit: .zero(instrument: .defaultTestInstrument),
      investmentIncome: .zero(instrument: .defaultTestInstrument),
      investmentExpense: .zero(instrument: .defaultTestInstrument),
      investmentProfit: .zero(instrument: .defaultTestInstrument)
    )
    #expect(item.hasUnavailableData == false)
  }

  @Test("MonthlyIncomeExpense stores hasUnavailableData: true when set")
  func monthlyIncomeExpenseStoredTrue() {
    let item = MonthlyIncomeExpense(
      month: "202601",
      start: Date(),
      end: Date(),
      income: .zero(instrument: .defaultTestInstrument),
      expense: .zero(instrument: .defaultTestInstrument),
      profit: .zero(instrument: .defaultTestInstrument),
      investmentIncome: .zero(instrument: .defaultTestInstrument),
      investmentExpense: .zero(instrument: .defaultTestInstrument),
      investmentProfit: .zero(instrument: .defaultTestInstrument),
      hasUnavailableData: true
    )
    #expect(item.hasUnavailableData == true)
  }

  @Test("MonthlyIncomeExpense Codable round-trips hasUnavailableData: true")
  func monthlyIncomeExpenseRoundTripTrue() throws {
    let original = MonthlyIncomeExpense(
      month: "202601",
      start: Date(timeIntervalSince1970: 0),
      end: Date(timeIntervalSince1970: 86400),
      income: .zero(instrument: .defaultTestInstrument),
      expense: .zero(instrument: .defaultTestInstrument),
      profit: .zero(instrument: .defaultTestInstrument),
      investmentIncome: .zero(instrument: .defaultTestInstrument),
      investmentExpense: .zero(instrument: .defaultTestInstrument),
      investmentProfit: .zero(instrument: .defaultTestInstrument),
      hasUnavailableData: true
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(MonthlyIncomeExpense.self, from: data)
    #expect(decoded.hasUnavailableData == true)
  }

  @Test("MonthlyIncomeExpense Codable round-trips hasUnavailableData: false")
  func monthlyIncomeExpenseRoundTripFalse() throws {
    let original = MonthlyIncomeExpense(
      month: "202601",
      start: Date(timeIntervalSince1970: 0),
      end: Date(timeIntervalSince1970: 86400),
      income: .zero(instrument: .defaultTestInstrument),
      expense: .zero(instrument: .defaultTestInstrument),
      profit: .zero(instrument: .defaultTestInstrument),
      investmentIncome: .zero(instrument: .defaultTestInstrument),
      investmentExpense: .zero(instrument: .defaultTestInstrument),
      investmentProfit: .zero(instrument: .defaultTestInstrument),
      hasUnavailableData: false
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(MonthlyIncomeExpense.self, from: data)
    #expect(decoded.hasUnavailableData == false)
  }

  @Test("MonthlyIncomeExpense decodes to false when hasUnavailableData key absent in JSON")
  func monthlyIncomeExpenseDecodesAbsentKeyAsFalse() throws {
    // Encode a full instance with the key present, then strip it from the JSON.
    let original = MonthlyIncomeExpense(
      month: "202601",
      start: Date(timeIntervalSince1970: 0),
      end: Date(timeIntervalSince1970: 86400),
      income: .zero(instrument: .defaultTestInstrument),
      expense: .zero(instrument: .defaultTestInstrument),
      profit: .zero(instrument: .defaultTestInstrument),
      investmentIncome: .zero(instrument: .defaultTestInstrument),
      investmentExpense: .zero(instrument: .defaultTestInstrument),
      investmentProfit: .zero(instrument: .defaultTestInstrument),
      hasUnavailableData: true
    )
    let encoded = try JSONEncoder().encode(original)
    var dict = try #require(
      try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    dict.removeValue(forKey: "hasUnavailableData")
    let strippedData = try JSONSerialization.data(withJSONObject: dict)
    let decoded = try JSONDecoder().decode(MonthlyIncomeExpense.self, from: strippedData)
    #expect(decoded.hasUnavailableData == false)
  }

  // MARK: - ExpenseBreakdown

  @Test("ExpenseBreakdown defaults hasUnavailableData to false when omitted")
  func expenseBreakdownDefaultsFalse() {
    let item = ExpenseBreakdown(
      categoryId: nil,
      month: "202601",
      totalExpenses: .zero(instrument: .defaultTestInstrument)
    )
    #expect(item.hasUnavailableData == false)
  }

  @Test("ExpenseBreakdown stores hasUnavailableData: true when set")
  func expenseBreakdownStoredTrue() {
    let item = ExpenseBreakdown(
      categoryId: nil,
      month: "202601",
      totalExpenses: .zero(instrument: .defaultTestInstrument),
      hasUnavailableData: true
    )
    #expect(item.hasUnavailableData == true)
  }

  @Test("ExpenseBreakdown Codable round-trips hasUnavailableData: true")
  func expenseBreakdownRoundTripTrue() throws {
    let original = ExpenseBreakdown(
      categoryId: UUID(),
      month: "202601",
      totalExpenses: .zero(instrument: .defaultTestInstrument),
      hasUnavailableData: true
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ExpenseBreakdown.self, from: data)
    #expect(decoded.hasUnavailableData == true)
  }

  @Test("ExpenseBreakdown Codable round-trips hasUnavailableData: false")
  func expenseBreakdownRoundTripFalse() throws {
    let original = ExpenseBreakdown(
      categoryId: UUID(),
      month: "202601",
      totalExpenses: .zero(instrument: .defaultTestInstrument),
      hasUnavailableData: false
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ExpenseBreakdown.self, from: data)
    #expect(decoded.hasUnavailableData == false)
  }

  @Test("ExpenseBreakdown decodes to false when hasUnavailableData key absent in JSON")
  func expenseBreakdownDecodesAbsentKeyAsFalse() throws {
    let original = ExpenseBreakdown(
      categoryId: UUID(),
      month: "202601",
      totalExpenses: .zero(instrument: .defaultTestInstrument),
      hasUnavailableData: true
    )
    let encoded = try JSONEncoder().encode(original)
    var dict = try #require(
      try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    dict.removeValue(forKey: "hasUnavailableData")
    let strippedData = try JSONSerialization.data(withJSONObject: dict)
    let decoded = try JSONDecoder().decode(ExpenseBreakdown.self, from: strippedData)
    #expect(decoded.hasUnavailableData == false)
  }
}

import Foundation
import Testing

@testable import Moolah

/// Tests that `GRDBAnalysisRepository.assembleIncomeAndExpense` honours
/// strict Rule 11 (#1077): a financial month whose aggregation had ANY
/// transient (price-unavailable) conversion failure is marked
/// `hasUnavailableData == true` — even when other rows in that month
/// converted successfully — and a month whose rows ALL transient-fail
/// still surfaces as a zeroed placeholder bucket rather than vanishing.
///
/// Rows are made to fail deterministically with the index-keyed
/// `ThrowingCountingConversionService`: the closure receives the
/// conversion call index, and each row in the fixtures contributes
/// exactly one non-zero column (so one conversion call per row, in row
/// order). Failing on a chosen index therefore fails exactly that row.
/// Transient failures use `WalletSyncError(.network)` (classified
/// transient by `ConversionFailureClassifier`, mirroring the existing
/// assemble suite); the structural case uses
/// `ConversionError.unsupportedConversion`.
@Suite("GRDBAnalysisRepository.assembleIncomeAndExpense — unavailable months (#1077)")
struct GRDBIncomeAndExpenseUnavailableTests {
  private static let usd = "USD"

  private func row(
    day: String, incomeQty: Int64
  ) -> GRDBAnalysisRepository.IncomeAndExpenseRow {
    .init(
      day: day, instrumentId: Self.usd,
      incomeQty: incomeQty, expenseQty: 0,
      investmentIncomeQty: 0, investmentExpenseQty: 0)
  }

  private func aggregation(
    _ rows: [GRDBAnalysisRepository.IncomeAndExpenseRow]
  ) -> GRDBAnalysisRepository.IncomeAndExpenseAggregation {
    .init(rows: rows, instrumentMap: [Self.usd: .fiat(code: Self.usd)])
  }

  private var noopHandlers: GRDBAnalysisRepository.IncomeAndExpenseHandlers {
    .init(handleUnparseableDay: { _ in }, handleConversionFailure: { _, _ in })
  }

  private func transientError() -> any Error {
    WalletSyncError(
      provider: .binance, kind: .network(underlyingDescription: "cooldown"))
  }

  @Test("partial month: one transient-failing row + one good row marks the month unavailable")
  func partialMonthMarkedUnavailableButKeepsGoodRow() async throws {
    // Two rows in the same financial month (Jan 2025, monthEnd 31).
    // Row 0 (call index 0) transient-fails; row 1 converts. The month
    // must surface with the surviving row's amount AND the unavailable flag.
    let aggregation = aggregation([
      row(day: "2025-01-10", incomeQty: 100),
      row(day: "2025-01-20", incomeQty: 200),
    ])
    let transient = transientError()
    let conversionService = ThrowingCountingConversionService { index in
      index == 0 ? .failure(transient) : .success(200)
    }

    let result = try await GRDBAnalysisRepository.assembleIncomeAndExpense(
      aggregation: aggregation,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversionService,
      monthEnd: 31,
      handlers: noopHandlers)

    let month = try #require(result.first { $0.month == "202501" })
    #expect(month.hasUnavailableData == true)
    // The surviving row (200) still contributes.
    #expect(month.income.quantity == 200)
    #expect(month.income.instrument == .defaultTestInstrument)
  }

  @Test("fully-unavailable month: every row transient-fails yet the month still appears, zeroed")
  func fullyUnavailableMonthEmittedAsZeroedPlaceholder() async throws {
    let aggregation = aggregation([
      row(day: "2025-03-05", incomeQty: 100),
      row(day: "2025-03-25", incomeQty: 200),
    ])
    let transient = transientError()
    let conversionService = ThrowingCountingConversionService { _ in
      .failure(transient)
    }

    let result = try await GRDBAnalysisRepository.assembleIncomeAndExpense(
      aggregation: aggregation,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversionService,
      monthEnd: 31,
      handlers: noopHandlers)

    // The month is present (NOT absent), flagged unavailable, zeroed.
    let month = try #require(result.first { $0.month == "202503" })
    #expect(month.hasUnavailableData == true)
    #expect(month.income == .zero(instrument: .defaultTestInstrument))
    #expect(month.expense == .zero(instrument: .defaultTestInstrument))
    #expect(month.profit == .zero(instrument: .defaultTestInstrument))

    // start/end span the failing rows' days, within the month.
    let firstDay = try #require(GRDBAnalysisRepository.parseDayString("2025-03-05"))
    let lastDay = try #require(GRDBAnalysisRepository.parseDayString("2025-03-25"))
    #expect(month.start == firstDay)
    #expect(month.end == lastDay)
  }

  @Test("clean month: no conversion failures leaves the month available")
  func cleanMonthNotMarkedUnavailable() async throws {
    let aggregation = aggregation([
      row(day: "2025-02-10", incomeQty: 100),
      row(day: "2025-02-20", incomeQty: 200),
    ])
    let conversionService = ThrowingCountingConversionService { _ in .success(50) }

    let result = try await GRDBAnalysisRepository.assembleIncomeAndExpense(
      aggregation: aggregation,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversionService,
      monthEnd: 31,
      handlers: noopHandlers)

    let month = try #require(result.first { $0.month == "202502" })
    #expect(month.hasUnavailableData == false)
  }

  @Test("structural conversion failure still rethrows")
  func structuralFailureRethrows() async throws {
    let aggregation = aggregation([
      row(day: "2025-04-10", incomeQty: 100)
    ])
    let conversionService = ThrowingCountingConversionService { _ in
      .failure(ConversionError.unsupportedConversion(from: "A", to: "B"))
    }

    await #expect(throws: ConversionError.self) {
      _ = try await GRDBAnalysisRepository.assembleIncomeAndExpense(
        aggregation: aggregation,
        profileInstrument: .defaultTestInstrument,
        conversionService: conversionService,
        monthEnd: 31,
        handlers: noopHandlers)
    }
  }
}

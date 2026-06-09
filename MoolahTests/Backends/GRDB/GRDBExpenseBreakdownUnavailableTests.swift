import Foundation
import Testing

@testable import Moolah

/// Tests that `GRDBAnalysisRepository.assembleExpenseBreakdown` honours
/// strict Rule 11 (#1077): a financial month whose aggregation had ANY
/// transient (price-unavailable) conversion failure is marked
/// `hasUnavailableData == true` on every emitted `ExpenseBreakdown` for
/// that month — even when other rows in that month converted
/// successfully — and a month whose rows ALL transient-fail still
/// surfaces as a zeroed `categoryId: nil` placeholder rather than
/// vanishing as "no activity".
///
/// Each fixture row contributes exactly one conversion call (one
/// `(day, category, instrument)` SUM row), in row order, so failing a
/// chosen call index fails exactly that row. Transient failures use
/// `WalletSyncError(.network)` (classified transient by
/// `ConversionFailureClassifier`, mirroring the existing assemble
/// suite); the structural case uses
/// `ConversionError.unsupportedConversion`.
@Suite("GRDBAnalysisRepository.assembleExpenseBreakdown — unavailable months (#1077)")
struct GRDBExpenseBreakdownUnavailableTests {
  private static let usd = "USD"

  private func row(
    day: String, categoryId: UUID?, qty: Int64
  ) -> GRDBAnalysisRepository.ExpenseBreakdownRow {
    .init(day: day, categoryId: categoryId, instrumentId: Self.usd, qty: qty)
  }

  private func aggregation(
    _ rows: [GRDBAnalysisRepository.ExpenseBreakdownRow]
  ) -> GRDBAnalysisRepository.ExpenseBreakdownAggregation {
    .init(rows: rows, instrumentMap: [Self.usd: .fiat(code: Self.usd)])
  }

  private var noopHandlers: GRDBAnalysisRepository.ExpenseBreakdownHandlers {
    .init(handleUnparseableDay: { _ in }, handleConversionFailure: { _, _ in })
  }

  private func transientError() -> any Error {
    WalletSyncError(
      provider: .binance, kind: .network(underlyingDescription: "cooldown"))
  }

  @Test("partial month: one transient-failing row + one good row marks the month unavailable")
  func partialMonthMarkedUnavailableButKeepsGoodRow() async throws {
    // Two rows in the same financial month (Jan 2025, monthEnd 31), in
    // different categories. Row 0 (call index 0) transient-fails; row 1
    // converts. Every emitted row for the month must carry the
    // unavailable flag, and the surviving category's total is present.
    let categoryA = UUID()
    let categoryB = UUID()
    let aggregation = aggregation([
      row(day: "2025-01-10", categoryId: categoryA, qty: -100),
      row(day: "2025-01-20", categoryId: categoryB, qty: -200),
    ])
    let transient = transientError()
    let conversionService = ThrowingCountingConversionService { index in
      index == 0 ? .failure(transient) : .success(-200)
    }

    let result = try await GRDBAnalysisRepository.assembleExpenseBreakdown(
      aggregation: aggregation,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversionService,
      monthEnd: 31,
      handlers: noopHandlers)

    let monthRows = result.filter { $0.month == "202501" }
    #expect(!monthRows.isEmpty)
    #expect(monthRows.allSatisfy { $0.hasUnavailableData })
    // The surviving category (B) still contributes its converted total.
    let survivor = try #require(monthRows.first { $0.categoryId == categoryB })
    #expect(survivor.totalExpenses.quantity == -200)
    #expect(survivor.totalExpenses.instrument == .defaultTestInstrument)
  }

  @Test(
    "fully-unavailable month: every row transient-fails yet the month still appears as a zeroed placeholder"
  )
  func fullyUnavailableMonthEmittedAsPlaceholder() async throws {
    let aggregation = aggregation([
      row(day: "2025-03-05", categoryId: UUID(), qty: -100),
      row(day: "2025-03-25", categoryId: UUID(), qty: -200),
    ])
    let transient = transientError()
    let conversionService = ThrowingCountingConversionService { _ in
      .failure(transient)
    }

    let result = try await GRDBAnalysisRepository.assembleExpenseBreakdown(
      aggregation: aggregation,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversionService,
      monthEnd: 31,
      handlers: noopHandlers)

    // The month is present (NOT absent) as a single nil-category,
    // zeroed, unavailable placeholder.
    let monthRows = result.filter { $0.month == "202503" }
    let placeholder = try #require(monthRows.first { $0.categoryId == nil })
    #expect(placeholder.hasUnavailableData == true)
    #expect(placeholder.totalExpenses == .zero(instrument: .defaultTestInstrument))
  }

  @Test("clean month: no conversion failures leaves every row available with no placeholder")
  func cleanMonthNotMarkedUnavailable() async throws {
    let categoryA = UUID()
    let categoryB = UUID()
    let aggregation = aggregation([
      row(day: "2025-02-10", categoryId: categoryA, qty: -100),
      row(day: "2025-02-20", categoryId: categoryB, qty: -200),
    ])
    let conversionService = ThrowingCountingConversionService { _ in .success(-50) }

    let result = try await GRDBAnalysisRepository.assembleExpenseBreakdown(
      aggregation: aggregation,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversionService,
      monthEnd: 31,
      handlers: noopHandlers)

    let monthRows = result.filter { $0.month == "202502" }
    #expect(!monthRows.isEmpty)
    #expect(monthRows.allSatisfy { !$0.hasUnavailableData })
    // No nil-category placeholder is synthesised for a clean month.
    #expect(monthRows.allSatisfy { $0.categoryId != nil })
  }

  @Test("structural conversion failure still rethrows")
  func structuralFailureRethrows() async throws {
    let aggregation = aggregation([
      row(day: "2025-04-10", categoryId: UUID(), qty: -100)
    ])
    let conversionService = ThrowingCountingConversionService { _ in
      .failure(ConversionError.unsupportedConversion(from: "A", to: "B"))
    }

    await #expect(throws: ConversionError.self) {
      _ = try await GRDBAnalysisRepository.assembleExpenseBreakdown(
        aggregation: aggregation,
        profileInstrument: .defaultTestInstrument,
        conversionService: conversionService,
        monthEnd: 31,
        handlers: noopHandlers)
    }
  }
}

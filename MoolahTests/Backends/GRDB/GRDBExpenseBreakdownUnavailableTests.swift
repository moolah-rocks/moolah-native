import Foundation
import Testing

@testable import Moolah

/// Tests that `GRDBAnalysisRepository.assembleExpenseBreakdown` honours
/// strict Rule 11 (#1077): a recognised conversion failure marks only its
/// dependent `(month, category)` total unavailable. Independently computed
/// sibling categories keep rendering, while an unavailable key with no
/// converted rows still surfaces as a zeroed placeholder retaining its
/// category identity rather than vanishing as "no activity".
///
/// Each fixture row contributes exactly one conversion call (one
/// `(day, category, instrument)` SUM row), in row order, so failing a
/// chosen call index fails exactly that row. Transient failures use
/// `WalletSyncError(.network)` (classified transient by
/// `ConversionFailureClassifier`, mirroring the existing assemble
/// suite); the permanent unavailable case uses
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

  @Test("one unavailable category does not blank its sibling category")
  func unavailableCategoryDoesNotBlankSibling() async throws {
    // Two rows in the same financial month (Jan 2025, monthEnd 31), in
    // different categories. Row 0 (call index 0) transient-fails; row 1
    // converts. Only category A's dependent total is unavailable.
    let categoryA = UUID()
    let categoryB = UUID()
    let aggregation = aggregation([
      row(day: "2025-01-10", categoryId: categoryA, qty: -100),
      row(day: "2025-01-20", categoryId: categoryB, qty: -200),
    ])
    let transient = transientError()
    let conversionService = FakeConversionService.perCall { index in
      index == 0 ? .failure(transient) : .success(-200)
    }

    let result = try await GRDBAnalysisRepository.assembleExpenseBreakdown(
      aggregation: aggregation,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversionService,
      monthEnd: 31,
      handlers: noopHandlers)

    let monthRows = result.filter { $0.month == "202501" }
    let unavailable = try #require(monthRows.first { $0.categoryId == categoryA })
    #expect(unavailable.hasUnavailableData)
    #expect(unavailable.totalExpenses == .zero(instrument: .defaultTestInstrument))
    let survivor = try #require(monthRows.first { $0.categoryId == categoryB })
    #expect(!survivor.hasUnavailableData)
    #expect(survivor.totalExpenses.quantity == -200)
    #expect(survivor.totalExpenses.instrument == .defaultTestInstrument)
  }

  @Test(
    "fully-unavailable month: every row transient-fails yet the month still appears as a zeroed placeholder"
  )
  func fullyUnavailableMonthEmittedAsPlaceholder() async throws {
    let categoryA = UUID()
    let categoryB = UUID()
    let aggregation = aggregation([
      row(day: "2025-03-05", categoryId: categoryA, qty: -100),
      row(day: "2025-03-25", categoryId: categoryB, qty: -200),
    ])
    let transient = transientError()
    let conversionService = FakeConversionService.perCall { _ in
      .failure(transient)
    }

    let result = try await GRDBAnalysisRepository.assembleExpenseBreakdown(
      aggregation: aggregation,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversionService,
      monthEnd: 31,
      handlers: noopHandlers)

    // Both unavailable logical totals remain present with their category IDs.
    let monthRows = result.filter { $0.month == "202503" }
    #expect(Set(monthRows.compactMap(\.categoryId)) == [categoryA, categoryB])
    #expect(monthRows.allSatisfy { $0.hasUnavailableData })
    #expect(
      monthRows.allSatisfy {
        $0.totalExpenses == .zero(instrument: .defaultTestInstrument)
      })
  }

  @Test("clean month: no conversion failures leaves every row available with no placeholder")
  func cleanMonthNotMarkedUnavailable() async throws {
    let categoryA = UUID()
    let categoryB = UUID()
    let aggregation = aggregation([
      row(day: "2025-02-10", categoryId: categoryA, qty: -100),
      row(day: "2025-02-20", categoryId: categoryB, qty: -200),
    ])
    let conversionService = FakeConversionService.perCall { _ in .success(-50) }

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

  @Test("unsupported conversion marks the month unavailable")
  func unsupportedConversionMarksMonthUnavailable() async throws {
    let aggregation = aggregation([
      row(day: "2025-04-10", categoryId: UUID(), qty: -100)
    ])
    let conversionService = FakeConversionService.perCall { _ in
      .failure(ConversionError.unsupportedConversion(from: "A", to: "B"))
    }

    let result = try await GRDBAnalysisRepository.assembleExpenseBreakdown(
      aggregation: aggregation,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversionService,
      monthEnd: 31,
      handlers: noopHandlers)

    let month = try #require(result.first)
    #expect(month.hasUnavailableData)
  }
}

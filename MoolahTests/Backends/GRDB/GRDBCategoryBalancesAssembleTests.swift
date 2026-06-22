import Foundation
import Testing

@testable import Moolah

/// Direct unit tests for `GRDBAnalysisRepository.assembleCategoryBalances`
/// — the SQL-aggregation post-processor that converts each
/// `(day, category, instrument)` row to the target instrument and
/// accumulates totals per category.
///
/// These tests drive the static helper directly with an injected
/// throwing conversion service (`FakeConversionService.perCall` from
/// `MoolahTests/Support/`) so the per-row error contract required by
/// `INSTRUMENT_CONVERSION_GUIDE.md` Rule 11 is captured by a unit test
/// (no GRDB stack needed). A future refactor that collapses the per-row
/// `do/catch` shape — e.g. wrapping the entire loop in an outer catch
/// and logging once — will trip the failure-count and rethrow assertions
/// below.
@Suite("GRDBAnalysisRepository.assembleCategoryBalances — Rule 11 contract")
struct GRDBCategoryBalancesAssembleTests {
  /// Build a three-row aggregation of USD legs over consecutive days
  /// against the default test instrument as the target. Three rows is
  /// enough to observe both per-row callback fan-out and
  /// loop-continues-after-failure behaviour.
  private func makeAggregation()
    -> GRDBAnalysisRepository.CategoryBalancesAggregation
  {
    let usd = "USD"
    let categoryA = UUID()
    let categoryB = UUID()
    let categoryC = UUID()
    let rows: [GRDBAnalysisRepository.CategoryBalancesRow] = [
      .init(day: "2025-01-15", categoryId: categoryA, instrumentId: usd, qty: -100),
      .init(day: "2025-01-16", categoryId: categoryB, instrumentId: usd, qty: -200),
      .init(day: "2025-01-17", categoryId: categoryC, instrumentId: usd, qty: -300),
    ]
    let instrumentMap: [String: Instrument] = [usd: .fiat(code: usd)]
    return .init(rows: rows, instrumentMap: instrumentMap)
  }

  private struct CallbackError: Error, Equatable {
    let index: Int
  }

  @Test("handleConversionFailure invoked once per failing row before rethrow")
  func handleConversionFailureFiresPerRow() async throws {
    let aggregation = makeAggregation()
    let conversionService = FakeConversionService.perCall { index in
      .failure(CallbackError(index: index))
    }
    let failures = FailureLog()
    let handlers = GRDBAnalysisRepository.CategoryBalancesHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { error, _ in
        if let callback = error as? CallbackError {
          failures.append(callback.index)
        }
      })

    await #expect(throws: CallbackError.self) {
      _ = try await GRDBAnalysisRepository.assembleCategoryBalances(
        aggregation: aggregation,
        targetInstrument: .defaultTestInstrument,
        conversionService: conversionService,
        handlers: handlers)
    }

    // Every row's failure surfaced through the per-row callback before
    // the function rethrew the first error. Three rows in, three callbacks
    // out — a refactor to "log once at the outer catch" would only fire
    // once and break this assertion.
    #expect(failures.snapshot() == [0, 1, 2])
    #expect(conversionService.callCount == 3)
  }

  @Test("loop processes all rows even when the first row fails")
  func loopContinuesAfterFirstFailure() async throws {
    let aggregation = makeAggregation()
    let conversionService = FakeConversionService.perCall { index in
      index == 0 ? .failure(CallbackError(index: index)) : .success(0)
    }
    let visited = FailureLog()
    let handlers = GRDBAnalysisRepository.CategoryBalancesHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { error, _ in
        if let callback = error as? CallbackError {
          visited.append(callback.index)
        }
      })

    await #expect(throws: CallbackError.self) {
      _ = try await GRDBAnalysisRepository.assembleCategoryBalances(
        aggregation: aggregation,
        targetInstrument: .defaultTestInstrument,
        conversionService: conversionService,
        handlers: handlers)
    }

    // Exactly one failure logged (the first row), but all three rows
    // were converted — the loop did NOT short-circuit on the first
    // throw. A refactor that breaks early would log [0] and call the
    // service once, not three times.
    #expect(visited.snapshot() == [0])
    #expect(conversionService.callCount == 3)
  }

  @Test("CancellationError rethrown immediately without invoking handleConversionFailure")
  func cancellationErrorIsNotFoldedIntoConversionFailureLog() async throws {
    let aggregation = makeAggregation()
    let conversionService = FakeConversionService.perCall { index in
      index == 0 ? .failure(CancellationError()) : .success(0)
    }
    let visited = FailureLog()
    let handlers = GRDBAnalysisRepository.CategoryBalancesHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { _, _ in
        visited.append(-1)
      })

    await #expect(throws: CancellationError.self) {
      _ = try await GRDBAnalysisRepository.assembleCategoryBalances(
        aggregation: aggregation,
        targetInstrument: .defaultTestInstrument,
        conversionService: conversionService,
        handlers: handlers)
    }

    // CancellationError surfaced unchanged — the per-row failure log
    // never fired, and the loop short-circuited on the first row
    // (no further conversion calls beyond the cancelled one).
    #expect(visited.snapshot().isEmpty)
    #expect(conversionService.callCount == 1)
  }
}

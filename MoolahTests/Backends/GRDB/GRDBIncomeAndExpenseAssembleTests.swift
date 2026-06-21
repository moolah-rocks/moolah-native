import Foundation
import Testing

@testable import Moolah

/// Direct unit tests for `GRDBAnalysisRepository.assembleIncomeAndExpense`
/// — the SQL-aggregation post-processor that converts each
/// `(day, instrument)` row's six conditional sums to the profile
/// instrument and accumulates into financial-month buckets.
///
/// These tests drive the static helper directly with an injected
/// throwing conversion service (`ThrowingCountingConversionService` from
/// `MoolahTests/Support/`) so the per-row error contract required by
/// `INSTRUMENT_CONVERSION_GUIDE.md` Rule 11 is captured by a unit test
/// (no GRDB stack needed). A future refactor that collapses the per-row
/// `do/catch` shape — e.g. wrapping the entire loop in an outer catch
/// and logging once — will trip the failure-count and rethrow assertions
/// below.
///
/// Mirrors `GRDBExpenseBreakdownAssembleTests` /
/// `GRDBCategoryBalancesAssembleTests`. Per-row failure here means a
/// single row in the `(day, instrument)` aggregation — every row carries
/// six summed columns, but the row converts as a unit because each leg's
/// quantity is already converted at the row's `day`.
@Suite("GRDBAnalysisRepository.assembleIncomeAndExpense — Rule 11 contract")
struct GRDBIncomeAndExpenseAssembleTests {
  /// Build a three-row aggregation of USD legs over consecutive days
  /// against the default test instrument as the profile target. Three
  /// rows is enough to observe both per-row callback fan-out and
  /// loop-continues-after-failure behaviour. Each row carries an
  /// `income_qty` so the conversion service is exercised on every row.
  private func makeAggregation()
    -> GRDBAnalysisRepository.IncomeAndExpenseAggregation
  {
    let usd = "USD"
    let rows: [GRDBAnalysisRepository.IncomeAndExpenseRow] = [
      .init(
        day: "2025-01-15", instrumentId: usd,
        incomeQty: 100, expenseQty: 0,
        investmentIncomeQty: 0, investmentExpenseQty: 0),
      .init(
        day: "2025-01-16", instrumentId: usd,
        incomeQty: 200, expenseQty: 0,
        investmentIncomeQty: 0, investmentExpenseQty: 0),
      .init(
        day: "2025-01-17", instrumentId: usd,
        incomeQty: 300, expenseQty: 0,
        investmentIncomeQty: 0, investmentExpenseQty: 0),
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
    let conversionService = ThrowingCountingConversionService { index in
      .failure(CallbackError(index: index))
    }
    let failures = FailureLog()
    let handlers = GRDBAnalysisRepository.IncomeAndExpenseHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { error, _ in
        if let callback = error as? CallbackError {
          failures.append(callback.index)
        }
      })

    await #expect(throws: CallbackError.self) {
      _ = try await GRDBAnalysisRepository.assembleIncomeAndExpense(
        aggregation: aggregation,
        profileInstrument: .defaultTestInstrument,
        conversionService: conversionService,
        monthEnd: 25,
        handlers: handlers)
    }

    // Every row's failure surfaced through the per-row callback before
    // the function rethrew the first error. Three rows in, three
    // callbacks out — a refactor to "log once at the outer catch" would
    // only fire once and break this assertion.
    #expect(failures.snapshot() == [0, 1, 2])
    // Each row converts only its non-zero columns. The fixture sets
    // exactly one non-zero column (incomeQty) per row, so one conversion
    // call per row.
    #expect(conversionService.calls == 3)
  }

  @Test("loop processes all rows even when the first row fails")
  func loopContinuesAfterFirstFailure() async throws {
    let aggregation = makeAggregation()
    let conversionService = ThrowingCountingConversionService { index in
      index == 0 ? .failure(CallbackError(index: index)) : .success(0)
    }
    let visited = FailureLog()
    let handlers = GRDBAnalysisRepository.IncomeAndExpenseHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { error, _ in
        if let callback = error as? CallbackError {
          visited.append(callback.index)
        }
      })

    await #expect(throws: CallbackError.self) {
      _ = try await GRDBAnalysisRepository.assembleIncomeAndExpense(
        aggregation: aggregation,
        profileInstrument: .defaultTestInstrument,
        conversionService: conversionService,
        monthEnd: 25,
        handlers: handlers)
    }

    // Exactly one failure logged (the first row), but all three rows
    // were converted — the loop did NOT short-circuit on the first
    // throw. A refactor that breaks early would log [0] and call the
    // service once, not three times.
    #expect(visited.snapshot() == [0])
    #expect(conversionService.calls == 3)
  }

  @Test("transient conversion failures degrade per-row — no rethrow")
  func transientFailuresDoNotRethrow() async throws {
    let aggregation = makeAggregation()
    let conversionService = ThrowingCountingConversionService { _ in
      .failure(
        WalletSyncError(provider: .binance, kind: .network(underlyingDescription: "cooldown")))
    }
    let failures = FailureLog()
    let handlers = GRDBAnalysisRepository.IncomeAndExpenseHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { _, _ in failures.append(0) })

    let result = try await GRDBAnalysisRepository.assembleIncomeAndExpense(
      aggregation: aggregation,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversionService,
      monthEnd: 25,
      handlers: handlers)

    // Every row was transient → none threw. Strict Rule 11 (#1077): the
    // month all of whose rows transient-skipped now surfaces as a single
    // zeroed placeholder bucket flagged unavailable (rather than the
    // pre-#1077 empty result, which was indistinguishable from "no
    // activity"). Detailed placeholder shape is pinned by
    // `GRDBIncomeAndExpenseUnavailableTests`.
    let month = try #require(result.first)
    #expect(month.hasUnavailableData == true)
    #expect(month.income == .zero(instrument: .defaultTestInstrument))
    // Handler still fired for every failing row (diagnostics preserved).
    #expect(!failures.snapshot().isEmpty)
  }

  @Test("structural conversion failures still rethrow")
  func structuralFailuresRethrow() async throws {
    let aggregation = makeAggregation()
    let conversionService = ThrowingCountingConversionService { _ in
      .failure(ConversionError.unsupportedConversion(from: "A", to: "B"))
    }
    let handlers = GRDBAnalysisRepository.IncomeAndExpenseHandlers(
      handleUnparseableDay: { _ in }, handleConversionFailure: { _, _ in })

    await #expect(throws: ConversionError.self) {
      _ = try await GRDBAnalysisRepository.assembleIncomeAndExpense(
        aggregation: aggregation,
        profileInstrument: .defaultTestInstrument,
        conversionService: conversionService,
        monthEnd: 25,
        handlers: handlers)
    }
  }

  @Test("convertRowSums converts each row at the row's own day, not Date()")
  func convertRowSumsUsesPerRowDay() async throws {
    // Pins that `assembleIncomeAndExpense` (and the `convertRowSums`
    // helper it drives) feeds the row's parsed `day` into the
    // conversion service per row — NOT a single `Date()` snapshot
    // captured at call time. A regression that swapped `day` for
    // `Date()` would silently pass against the existing
    // `ThrowingCountingConversionService` fixtures because that service
    // ignores the conversion date.
    //
    // The fixture here is two USD rows on different days with
    // different rates. If the helper were converting both rows at the
    // same date (e.g. `Date()`), both legs would convert at the same
    // rate and the totals would diverge from the per-day truth.
    let dayOneString = "2025-06-10"
    let dayTwoString = "2025-06-11"
    let dayOne = try #require(GRDBAnalysisRepository.parseDayString(dayOneString))
    let dayTwo = try #require(GRDBAnalysisRepository.parseDayString(dayTwoString))
    let usd = "USD"
    let rateOne = try AnalysisTestHelpers.decimal("1.5")
    let rateTwo = try AnalysisTestHelpers.decimal("2.0")
    let conversion = DateBasedFixedConversionService(
      rates: [
        dayOne: [usd: rateOne],
        dayTwo: [usd: rateTwo],
      ])
    // SQL aggregates emit values in `Int64` storage units (raw quantity
    // scaled by `storageScale = 10^8`). Use the scaled value here so the
    // post-conversion result is a recognisable integer.
    let scaledHundred: Int64 = 100 * 100_000_000
    let aggregation = GRDBAnalysisRepository.IncomeAndExpenseAggregation(
      rows: [
        .init(
          day: dayOneString, instrumentId: usd,
          incomeQty: scaledHundred, expenseQty: 0,
          investmentIncomeQty: 0, investmentExpenseQty: 0),
        .init(
          day: dayTwoString, instrumentId: usd,
          incomeQty: scaledHundred, expenseQty: 0,
          investmentIncomeQty: 0, investmentExpenseQty: 0),
      ],
      instrumentMap: [usd: .fiat(code: usd)])
    let handlers = GRDBAnalysisRepository.IncomeAndExpenseHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { _, _ in })

    let result = try await GRDBAnalysisRepository.assembleIncomeAndExpense(
      aggregation: aggregation,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversion,
      monthEnd: 25,
      handlers: handlers)

    // Both rows land in the same financial month (June 2025, monthEnd
    // 25) and collapse into one bucket. Per-day rates: 100 * 1.5 +
    // 100 * 2.0 = 350. A bug that converted both rows at `Date()` (or
    // any single date) would yield 100 * r + 100 * r = 200 * r — never
    // 350 unless `r` accidentally split as 1.75 — and the rate fixture
    // has no entry on `Date()` so it would 1:1-fall-back to 200.
    #expect(result.count == 1)
    let month = try #require(result.first)
    #expect(month.income.quantity == 350)
    #expect(month.income.instrument == .defaultTestInstrument)
  }

  @Test("CancellationError rethrown immediately without invoking handleConversionFailure")
  func cancellationErrorIsNotFoldedIntoConversionFailureLog() async throws {
    let aggregation = makeAggregation()
    let conversionService = ThrowingCountingConversionService { index in
      index == 0 ? .failure(CancellationError()) : .success(0)
    }
    let visited = FailureLog()
    let handlers = GRDBAnalysisRepository.IncomeAndExpenseHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { _, _ in
        visited.append(-1)
      })

    await #expect(throws: CancellationError.self) {
      _ = try await GRDBAnalysisRepository.assembleIncomeAndExpense(
        aggregation: aggregation,
        profileInstrument: .defaultTestInstrument,
        conversionService: conversionService,
        monthEnd: 25,
        handlers: handlers)
    }

    // CancellationError surfaced unchanged — the per-row failure log
    // never fired, and the loop short-circuited on the first row
    // (no further conversion calls beyond the cancelled one).
    #expect(visited.snapshot().isEmpty)
    #expect(conversionService.calls == 1)
  }
}

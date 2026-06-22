import Foundation
import Testing

@testable import Moolah

/// Direct unit tests for `GRDBAnalysisRepository.assembleExpenseBreakdown`
/// — the SQL-aggregation post-processor that converts each
/// `(day, category, instrument)` row to the profile instrument and
/// buckets into financial months.
///
/// These tests drive the static helper directly with an injected
/// throwing conversion service (`FakeConversionService.perCall` from
/// `MoolahTests/Support/`) so the per-row error contract required by
/// `INSTRUMENT_CONVERSION_GUIDE.md` Rule 11 is captured by a unit test
/// (no GRDB stack needed). A future refactor that collapses the per-row
/// `do/catch` shape — e.g. wrapping the entire loop in an outer catch
/// and logging once — will trip the failure-count and rethrow assertions
/// below.
@Suite("GRDBAnalysisRepository.assembleExpenseBreakdown — Rule 11 contract")
struct GRDBExpenseBreakdownAssembleTests {
  /// Build a three-row aggregation of USD legs over consecutive days
  /// against the default test instrument as the profile target. Three
  /// rows is enough to observe both per-row callback fan-out and
  /// loop-continues-after-failure behaviour.
  private func makeAggregation()
    -> GRDBAnalysisRepository.ExpenseBreakdownAggregation
  {
    let usd = "USD"
    let categoryA = UUID()
    let categoryB = UUID()
    let categoryC = UUID()
    let rows: [GRDBAnalysisRepository.ExpenseBreakdownRow] = [
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
    let handlers = GRDBAnalysisRepository.ExpenseBreakdownHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { error, _ in
        if let callback = error as? CallbackError {
          failures.append(callback.index)
        }
      })

    await #expect(throws: CallbackError.self) {
      _ = try await GRDBAnalysisRepository.assembleExpenseBreakdown(
        aggregation: aggregation,
        profileInstrument: .defaultTestInstrument,
        conversionService: conversionService,
        monthEnd: 25,
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
    let handlers = GRDBAnalysisRepository.ExpenseBreakdownHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { error, _ in
        if let callback = error as? CallbackError {
          visited.append(callback.index)
        }
      })

    await #expect(throws: CallbackError.self) {
      _ = try await GRDBAnalysisRepository.assembleExpenseBreakdown(
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
    #expect(conversionService.callCount == 3)
  }

  @Test("transient conversion failures degrade per-row — no rethrow")
  func transientFailuresDoNotRethrow() async throws {
    let aggregation = makeAggregation()
    let conversionService = FakeConversionService.perCall { _ in
      .failure(
        WalletSyncError(provider: .binance, kind: .network(underlyingDescription: "cooldown")))
    }
    let failures = FailureLog()
    let handlers = GRDBAnalysisRepository.ExpenseBreakdownHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { _, _ in failures.append(0) })

    let result = try await GRDBAnalysisRepository.assembleExpenseBreakdown(
      aggregation: aggregation,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversionService,
      monthEnd: 25,
      handlers: handlers)

    // Every row was transient → none threw. Strict Rule 11 (#1077): the
    // month all of whose rows transient-skipped now surfaces as a single
    // zeroed `categoryId: nil` placeholder flagged unavailable (rather
    // than the pre-#1077 empty result, which was indistinguishable from
    // "no activity"). Detailed placeholder shape is pinned by
    // `GRDBExpenseBreakdownUnavailableTests`.
    let placeholder = try #require(result.first)
    #expect(placeholder.categoryId == nil)
    #expect(placeholder.hasUnavailableData == true)
    #expect(placeholder.totalExpenses == .zero(instrument: .defaultTestInstrument))
    // Handler still fired for every failing row (diagnostics preserved).
    #expect(!failures.snapshot().isEmpty)
  }

  @Test("structural conversion failures still rethrow")
  func structuralFailuresRethrow() async throws {
    let aggregation = makeAggregation()
    let conversionService = FakeConversionService.perCall { _ in
      .failure(ConversionError.unsupportedConversion(from: "A", to: "B"))
    }
    let handlers = GRDBAnalysisRepository.ExpenseBreakdownHandlers(
      handleUnparseableDay: { _ in }, handleConversionFailure: { _, _ in })

    await #expect(throws: ConversionError.self) {
      _ = try await GRDBAnalysisRepository.assembleExpenseBreakdown(
        aggregation: aggregation,
        profileInstrument: .defaultTestInstrument,
        conversionService: conversionService,
        monthEnd: 25,
        handlers: handlers)
    }
  }

  @Test("assembleExpenseBreakdown converts each row at its own day, not Date()")
  func assembleUsesPerRowDay() async throws {
    // Pins that `assembleExpenseBreakdown` feeds each row's parsed `day`
    // into the conversion service per row — NOT a single `Date()` snapshot.
    // Two USD rows in the SAME category and financial month, on two days
    // with different rates: per-day conversion yields -100*1.5 + -100*2.0
    // = -350. A `Date()` bug would convert both at one rate (or 1:1-fall
    // back, since the fixture has no entry on `Date()`) → never -350.
    let dayOneString = "2025-06-10"
    let dayTwoString = "2025-06-11"
    let dayOne = try #require(GRDBAnalysisRepository.parseDayString(dayOneString))
    let dayTwo = try #require(GRDBAnalysisRepository.parseDayString(dayTwoString))
    let usd = "USD"
    let category = UUID()
    let rateOne = try AnalysisTestHelpers.decimal("1.5")
    let rateTwo = try AnalysisTestHelpers.decimal("2.0")
    let conversion = FakeConversionService.dateRates([
      dayOne: [usd: rateOne],
      dayTwo: [usd: rateTwo],
    ])
    // `ExpenseBreakdownRow.qty` is an `Int64` storage value (raw quantity
    // scaled by 10^8). Use the scaled value so the post-conversion result
    // is a recognisable integer.
    let scaledMinusHundred: Int64 = -100 * 100_000_000
    let aggregation = GRDBAnalysisRepository.ExpenseBreakdownAggregation(
      rows: [
        .init(day: dayOneString, categoryId: category, instrumentId: usd, qty: scaledMinusHundred),
        .init(day: dayTwoString, categoryId: category, instrumentId: usd, qty: scaledMinusHundred),
      ],
      instrumentMap: [usd: .fiat(code: usd)])
    let handlers = GRDBAnalysisRepository.ExpenseBreakdownHandlers(
      handleUnparseableDay: { _ in }, handleConversionFailure: { _, _ in })

    let result = try await GRDBAnalysisRepository.assembleExpenseBreakdown(
      aggregation: aggregation,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversion,
      monthEnd: 25,
      handlers: handlers)

    // Both rows collapse into one (June 2025, monthEnd 25) category
    // bucket. Per-day rates: -100*1.5 + -100*2.0 = -350. Any single-date
    // conversion would land elsewhere.
    #expect(result.count == 1)
    let breakdown = try #require(result.first)
    #expect(breakdown.totalExpenses.quantity == -350)
    #expect(breakdown.totalExpenses.instrument == .defaultTestInstrument)
  }

  @Test("CancellationError rethrown immediately without invoking handleConversionFailure")
  func cancellationErrorIsNotFoldedIntoConversionFailureLog() async throws {
    let aggregation = makeAggregation()
    let conversionService = FakeConversionService.perCall { index in
      index == 0 ? .failure(CancellationError()) : .success(0)
    }
    let visited = FailureLog()
    let handlers = GRDBAnalysisRepository.ExpenseBreakdownHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { _, _ in
        visited.append(-1)
      })

    await #expect(throws: CancellationError.self) {
      _ = try await GRDBAnalysisRepository.assembleExpenseBreakdown(
        aggregation: aggregation,
        profileInstrument: .defaultTestInstrument,
        conversionService: conversionService,
        monthEnd: 25,
        handlers: handlers)
    }

    // CancellationError surfaced unchanged — the per-row failure log
    // never fired, and the batch rethrew CancellationError after the
    // first element resolved; no further conversion calls issued.
    #expect(visited.snapshot().isEmpty)
    #expect(conversionService.callCount == 1)
  }
}

import Foundation
import Testing

@testable import Moolah

/// Direct unit tests for `GRDBAnalysisRepository.assembleDailyBalances` —
/// the SQL-aggregation post-processor that walks the per-day account /
/// earmark deltas, applies them to a `PositionBook`, and converts each
/// day's positions to the profile instrument via
/// `PositionBook.dailyBalance(...)`.
///
/// These tests drive the static helper directly with an injected
/// throwing conversion service (`FakeConversionService.perCall` from
/// `MoolahTests/Support/`) so the per-day error contract required by
/// `INSTRUMENT_CONVERSION_GUIDE.md` Rule 11 is captured by a unit test
/// (no GRDB stack needed).
///
/// **Daily-balance contract differs from the other analysis
/// aggregations.** Where `assembleExpenseBreakdown` /
/// `assembleCategoryBalances` / `assembleIncomeAndExpense` rethrow the
/// first conversion failure after logging every per-row callback, the
/// daily-balance walker logs each failure and *omits the failing day
/// from the result* without rethrowing. The chart renders a continuous
/// timeline; throwing on any per-day failure would erase every day
/// (including ones that *did* convert), defeating Rule 11 scoping. The
/// AnalysisRule11Scoping contract test pins the no-throw behaviour
/// from the public API; these unit tests pin the same shape on the
/// helper itself.
@Suite("GRDBAnalysisRepository.assembleDailyBalances — Rule 11 contract")
struct GRDBDailyBalancesAssembleTests {
  /// Build a three-day aggregation of single-account deltas (one
  /// non-investment account, three consecutive days, each with a
  /// foreign-instrument income leg). Three days is enough to observe
  /// per-day callback fan-out and loop-continues-after-failure
  /// behaviour. Each day exercises one foreign-instrument conversion
  /// inside `PositionBook.dailyBalance`.
  private func makeAggregation() throws
    -> (GRDBAnalysisRepository.DailyBalancesAggregation, UUID)
  {
    let usd = "USD"
    let accountId = UUID()
    let dayOne = try AnalysisTestHelpers.utcDate(year: 2025, month: 1, day: 15, hour: 12)
    let dayTwo = try AnalysisTestHelpers.utcDate(year: 2025, month: 1, day: 16, hour: 12)
    let dayThree = try AnalysisTestHelpers.utcDate(year: 2025, month: 1, day: 17, hour: 12)
    let accountRows: [GRDBAnalysisRepository.DailyBalanceAccountRow] = [
      .init(
        day: "2025-01-15", sampleDate: dayOne,
        accountId: accountId, instrumentId: usd,
        type: "income", qty: 100),
      .init(
        day: "2025-01-16", sampleDate: dayTwo,
        accountId: accountId, instrumentId: usd,
        type: "income", qty: 100),
      .init(
        day: "2025-01-17", sampleDate: dayThree,
        accountId: accountId, instrumentId: usd,
        type: "income", qty: 100),
    ]
    let aggregation = GRDBAnalysisRepository.DailyBalancesAggregation(
      priorAccountRows: [],
      priorEarmarkRows: [],
      accountRows: accountRows,
      earmarkRows: [],
      investmentValues: [],
      investmentAccountIds: [],
      tradesModeInvestmentAccountIds: [],
      priorTradesModeAccountRows: [],
      tradesModeAccountRows: [],
      scheduled: [],
      instrumentMap: [usd: .fiat(code: usd)],
      forecastUntil: nil)
    return (aggregation, accountId)
  }

  private struct CallbackError: Error, Equatable {
    let index: Int
  }

  @Test("handleConversionFailure invoked once per failing day; no rethrow")
  func handleConversionFailureFiresPerDay() async throws {
    let (aggregation, _) = try makeAggregation()
    let conversionService = FakeConversionService.perCall { index in
      .failure(CallbackError(index: index))
    }
    let failures = FailureLog()
    let handlers = GRDBAnalysisRepository.DailyBalancesHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { error, _ in
        if let callback = error as? CallbackError {
          failures.append(callback.index)
        }
      },
      handleInvestmentValueFailure: { _, _ in })

    // The walker MUST NOT throw on per-day conversion failure — Rule 11
    // scoping plus the chart-rendering rationale documented on
    // `assembleDailyBalances`. The result is the partially-populated
    // history (here, every day failed → empty array).
    let result = try await GRDBAnalysisRepository.assembleDailyBalances(
      aggregation: aggregation,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversionService,
      handlers: handlers)

    #expect(result.isEmpty)
    // Every day's failure surfaced through the per-day callback. Three
    // days in, three callbacks out — a refactor to "log once at the
    // outer catch" would only fire once and break this assertion.
    #expect(failures.snapshot() == [0, 1, 2])
    // Each day exercises exactly one conversion (one USD position in
    // the book on that day). The book is mutated in place so the same
    // position persists across days; `dailyBalance` calls the service
    // once per day's foreign-instrument bucket. Three days = three
    // calls.
    #expect(conversionService.callCount == 3)
  }

  @Test("loop processes all days even when the first day fails")
  func loopContinuesAfterFirstFailure() async throws {
    let (aggregation, _) = try makeAggregation()
    let conversionService = FakeConversionService.perCall { index in
      index == 0 ? .failure(CallbackError(index: index)) : .success(0)
    }
    let visited = FailureLog()
    let handlers = GRDBAnalysisRepository.DailyBalancesHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { error, _ in
        if let callback = error as? CallbackError {
          visited.append(callback.index)
        }
      },
      handleInvestmentValueFailure: { _, _ in })

    let result = try await GRDBAnalysisRepository.assembleDailyBalances(
      aggregation: aggregation,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversionService,
      handlers: handlers)

    // Exactly one failure logged (the first day), but all three days
    // were converted — the loop did NOT short-circuit on the first
    // throw. A refactor that breaks early would log [0] and call the
    // service once, not three times.
    #expect(visited.snapshot() == [0])
    #expect(conversionService.callCount == 3)
    // Day 0 is omitted; days 1 and 2 surface even though their
    // conversion returned 0 (the success branch). bestFit fills in
    // because the result has ≥2 entries.
    #expect(result.count == 2)
  }

  @Test("CancellationError rethrown immediately without invoking handleConversionFailure")
  func cancellationErrorIsNotFoldedIntoConversionFailureLog() async throws {
    let (aggregation, _) = try makeAggregation()
    let conversionService = FakeConversionService.perCall { index in
      index == 0 ? .failure(CancellationError()) : .success(0)
    }
    let visited = FailureLog()
    let handlers = GRDBAnalysisRepository.DailyBalancesHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { _, _ in
        visited.append(-1)
      },
      handleInvestmentValueFailure: { _, _ in })

    await #expect(throws: CancellationError.self) {
      _ = try await GRDBAnalysisRepository.assembleDailyBalances(
        aggregation: aggregation,
        profileInstrument: .defaultTestInstrument,
        conversionService: conversionService,
        handlers: handlers)
    }

    // CancellationError surfaced unchanged — the per-day failure log
    // never fired, and the loop short-circuited on the first day
    // (no further conversion calls beyond the cancelled one).
    #expect(visited.snapshot().isEmpty)
    #expect(conversionService.callCount == 1)
  }

  @Test("snapshot fold drops the day from dailyBalances on per-day conversion failure")
  func snapshotFoldDropsDayOnFailure() async throws {
    // Build an aggregation with one investment-value snapshot on day D.
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayKey = Calendar.current.startOfDay(for: day)
    let usd = Instrument.fiat(code: "USD")
    let accountId = UUID()
    let aggregation = makeSnapshotFoldAggregation(
      day: day, accountId: accountId, usd: usd)
    // Seed the dailyBalances dict directly so we test the fold in
    // isolation. Insert a placeholder DailyBalance for `dayKey` so the
    // fold has a key to drop.
    var dailyBalances: [Date: DailyBalance] = [
      dayKey: makePlaceholderDailyBalance(on: dayKey)
    ]
    let conversionService = FakeConversionService.dateRates([:], failingDates: [dayKey])
    let captured = InvestmentValueFailureLog()
    let handlers = GRDBAnalysisRepository.DailyBalancesHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { _, _ in },
      handleInvestmentValueFailure: { error, date in
        captured.append(error, date)
      })
    let context = GRDBAnalysisRepository.DailyBalancesAssemblyContext(
      investmentAccountIds: aggregation.investmentAccountIds,
      tradesModeInvestmentAccountIds: aggregation.tradesModeInvestmentAccountIds,
      instrumentMap: aggregation.instrumentMap,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversionService)

    try await GRDBAnalysisRepository.applyInvestmentValues(
      aggregation.investmentValues,
      to: &dailyBalances,
      context: context,
      handlers: handlers)

    // Rule 11: a snapshot conversion failure on day D must drop day D
    // from dailyBalances. Sibling days (none here) are unaffected.
    #expect(dailyBalances[dayKey] == nil)
    let snapshot = captured.snapshot()
    #expect(snapshot.count == 1)
    #expect(snapshot.first?.1 == dayKey)
  }

  /// Build a single-snapshot aggregation for the snapshot-fold Rule 11
  /// test. Extracted out of the test body to keep
  /// `snapshotFoldDropsDayOnFailure` under SwiftLint's function-body
  /// budget.
  private func makeSnapshotFoldAggregation(
    day: Date, accountId: UUID, usd: Instrument
  ) -> GRDBAnalysisRepository.DailyBalancesAggregation {
    GRDBAnalysisRepository.DailyBalancesAggregation(
      priorAccountRows: [],
      priorEarmarkRows: [],
      accountRows: [],
      earmarkRows: [],
      investmentValues: [
        InvestmentValueSnapshot(
          accountId: accountId, date: day,
          value: InstrumentAmount(quantity: 100, instrument: usd))
      ],
      investmentAccountIds: [accountId],
      tradesModeInvestmentAccountIds: [],
      priorTradesModeAccountRows: [],
      tradesModeAccountRows: [],
      scheduled: [],
      instrumentMap: ["USD": usd],
      forecastUntil: nil)
  }

  /// Zero-everything `DailyBalance` placeholder so the snapshot fold
  /// has an entry to remove. Same extraction reason as
  /// `makeSnapshotFoldAggregation`.
  private func makePlaceholderDailyBalance(on dayKey: Date) -> DailyBalance {
    DailyBalance(
      date: dayKey,
      balance: .zero(instrument: .defaultTestInstrument),
      earmarked: .zero(instrument: .defaultTestInstrument),
      availableFunds: .zero(instrument: .defaultTestInstrument),
      investments: .zero(instrument: .defaultTestInstrument),
      investmentValue: nil,
      netWorth: .zero(instrument: .defaultTestInstrument),
      bestFit: nil,
      isForecast: false)
  }
}

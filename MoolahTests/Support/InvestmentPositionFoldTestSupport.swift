import Foundation

@testable import Moolah

/// Shared helpers for the investment-position valuation fold tests
/// (`DailyBalanceInvestmentPositionTests` and its sibling suites).
enum InvestmentPositionFoldTestSupport {

  /// Build the standard `DailyBalancesHandlers` for fold-contract
  /// tests. The investment-position fold only ever invokes
  /// `handlePositionValuationFailure` — the other two callbacks are
  /// no-ops. Pass `PositionValuationFailureLog.append` (or a
  /// `{ _, _ in }` no-op for cases that don't assert on failures).
  static func makeHandlers(
    failures: @escaping @Sendable (Error, Date) -> Void
  ) -> GRDBAnalysisRepository.DailyBalancesHandlers {
    GRDBAnalysisRepository.DailyBalancesHandlers(
      handleUnparseableDay: { _ in },
      handleConversionFailure: { _, _ in },
      handlePositionValuationFailure: failures)
  }

  /// Zero-everything `DailyBalance` placeholder so the fold has an
  /// entry to look up / drop on the given day.
  static func placeholderBalance(at dayKey: Date) -> DailyBalance {
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

  /// Pre-seeded `DailyBalance` carrying a stale investment value. Used by
  /// tests that exercise the fold's replace-not-add contract.
  static func preSeededDailyBalance(on dayKey: Date) -> DailyBalance {
    DailyBalance(
      date: dayKey,
      balance: InstrumentAmount(
        quantity: 10, instrument: .defaultTestInstrument),
      earmarked: .zero(instrument: .defaultTestInstrument),
      availableFunds: InstrumentAmount(
        quantity: 10, instrument: .defaultTestInstrument),
      investments: .zero(instrument: .defaultTestInstrument),
      investmentValue: InstrumentAmount(
        quantity: 100, instrument: .defaultTestInstrument),
      netWorth: InstrumentAmount(
        quantity: 110, instrument: .defaultTestInstrument),
      bestFit: nil,
      isForecast: false)
  }

  /// Build a `DailyBalancesAssemblyContext` parameterised for the
  /// investment-position fold: explicit account ids, instrument map, and
  /// conversion service. Profile instrument is the default test instrument (AUD).
  static func makeContext(
    investmentIds: Set<UUID>,
    instrumentMap: [String: Instrument],
    conversionService: any InstrumentConversionService
  ) -> GRDBAnalysisRepository.DailyBalancesAssemblyContext {
    GRDBAnalysisRepository.DailyBalancesAssemblyContext(
      investmentAccountIds: investmentIds,
      instrumentMap: instrumentMap,
      profileInstrument: .defaultTestInstrument,
      conversionService: conversionService)
  }
}

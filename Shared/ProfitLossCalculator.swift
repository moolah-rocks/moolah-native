import Foundation

/// Computes per-instrument profit/loss from transaction history.
///
/// Combines FIFO cost basis tracking with current market valuation.
enum ProfitLossCalculator {
  /// Retained convenience for unit-test call sites: builds a profile-wide
  /// `HoldingsCostLedger` from `LegTransaction`s then projects. Production
  /// (`ReportingStore`) uses `compute(ledger:…)` with the shared
  /// `HoldingsCostLedgerStore` ledger so the build is not repeated.
  static func compute(
    transactions: [LegTransaction],
    profileCurrency: Instrument,
    conversionService: InstrumentConversionService,
    asOfDate: Date
  ) async throws -> [InstrumentProfitLoss] {
    let txns = transactions.map { Transaction(date: $0.date, legs: $0.legs) }
    let ledger = try await HoldingsCostLedger.build(
      transactions: txns,
      referenceCurrency: profileCurrency,
      conversionService: conversionService)
    return try await compute(
      ledger: ledger,
      profileCurrency: profileCurrency,
      conversionService: conversionService,
      asOfDate: asOfDate)
  }

  /// Pure per-instrument P&L projection from a pre-built profile-wide ledger.
  ///
  /// `totalInvested` is reconciled with the shared ledger's acquisition
  /// flows — the external capital that entered each instrument's holdings
  /// (`counterpartyAccount == nil && amount > 0`, i.e. fiat-paired buys AND
  /// income/opening-balance receipts valued at market, but NOT the receiving
  /// side of an internal transfer). This folds transaction fees in (they are
  /// already in each acquisition's per-unit cost via `TradeEventClassifier`)
  /// so `totalInvested` stays consistent with the FIFO `remainingCostBasis`,
  /// keeping `returnPercentage` honest. Realised gains and open lots come
  /// from the same ledger; `currentValue` market-values the open quantity at
  /// `asOfDate` (Rule 6). See guides/INSTRUMENT_CONVERSION_GUIDE.md Rules 1,
  /// 5, 6, and 8.
  static func compute(
    ledger: HoldingsCostLedger,
    profileCurrency: Instrument,
    conversionService: InstrumentConversionService,
    asOfDate: Date
  ) async throws -> [InstrumentProfitLoss] {
    var instrumentData: [String: InstrumentData] = [:]
    for entry in ledger.flows where entry.counterpartyAccount == nil && entry.amount > 0 {
      instrumentData[entry.instrument.id, default: InstrumentData(instrument: entry.instrument)]
        .totalInvested += entry.amount
    }
    for event in ledger.realisedEvents {
      instrumentData[event.instrument.id, default: InstrumentData(instrument: event.instrument)]
        .realizedGain += event.gain
    }
    for lot in ledger.openLots {
      let id = lot.instrument.id
      instrumentData[id, default: InstrumentData(instrument: lot.instrument)]
        .currentQuantity += lot.remainingQuantity
      instrumentData[id, default: InstrumentData(instrument: lot.instrument)]
        .remainingCostBasis += lot.remainingCost
    }

    return try await buildResults(
      from: instrumentData,
      profileCurrency: profileCurrency,
      conversionService: conversionService,
      asOfDate: asOfDate)
  }

  private static func buildResults(
    from instrumentData: [String: InstrumentData],
    profileCurrency: Instrument,
    conversionService: InstrumentConversionService,
    asOfDate: Date
  ) async throws -> [InstrumentProfitLoss] {
    var results: [InstrumentProfitLoss] = []
    for (_, data) in instrumentData {
      var currentValue: Decimal = 0
      if data.currentQuantity > 0 {
        currentValue = try await conversionService.convert(
          data.currentQuantity, from: data.instrument, to: profileCurrency, on: asOfDate
        )
      }
      let unrealized = currentValue - data.remainingCostBasis
      results.append(
        InstrumentProfitLoss(
          instrument: data.instrument,
          currentQuantity: data.currentQuantity,
          totalInvested: data.totalInvested,
          currentValue: currentValue,
          realizedGain: data.realizedGain,
          unrealizedGain: unrealized
        ))
    }
    return results.sorted { $0.totalGain > $1.totalGain }
  }

  private struct InstrumentData {
    let instrument: Instrument
    var totalInvested: Decimal = 0
    var realizedGain: Decimal = 0
    var currentQuantity: Decimal = 0
    var remainingCostBasis: Decimal = 0
  }
}

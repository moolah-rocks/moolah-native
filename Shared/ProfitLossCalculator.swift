import Foundation
import os

/// Per-instrument P&L rows plus the Rule 11 unavailability set.
struct ProfitLossResult: Sendable {
  let rows: [InstrumentProfitLoss]
  /// Instrument ids whose cost-basis history hit an unresolvable conversion
  /// during the ledger build (Rule 11). Their rows are OMITTED from `rows`
  /// (a partial row would look complete); the caller surfaces them as
  /// "unavailable" rather than "no position."
  let unavailableInstrumentIds: Set<String>
  let unavailableInstruments: Set<Instrument>
}

/// Computes per-instrument profit/loss from transaction history.
///
/// Combines FIFO cost basis tracking with current market valuation.
enum ProfitLossCalculator {
  private static let logger = Logger(subsystem: "rocks.moolah.app", category: "ProfitLoss")

  /// Retained convenience for unit-test call sites: builds a profile-wide
  /// `HoldingsCostLedger` from `LegTransaction`s then projects, returning just
  /// the rows. Production (`ReportingStore`) uses `compute(ledger:…)` with the
  /// shared `HoldingsCostLedgerStore` ledger (and reads its
  /// `unavailableInstrumentIds`) so the build is not repeated.
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
      asOfDate: asOfDate
    ).rows
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
  ///
  /// Rule 11: instruments in `ledger.unavailableInstrumentIds` (a genuine
  /// conversion failure touched their history) are OMITTED from `rows` — a
  /// row assembled from their surviving flows/lots would look complete but be
  /// understated — and returned in `unavailableInstrumentIds` so the caller
  /// marks them unavailable. Sibling instruments still render.
  static func compute(
    ledger: HoldingsCostLedger,
    profileCurrency: Instrument,
    conversionService: InstrumentConversionService,
    asOfDate: Date
  ) async throws -> ProfitLossResult {
    let unavailable = ledger.unavailableInstrumentIds
    var instrumentData: [String: InstrumentData] = [:]
    for entry in ledger.flows
    where entry.counterpartyAccount == nil && entry.amount > 0
      && !unavailable.contains(entry.instrument.id)
    {
      instrumentData[entry.instrument.id, default: InstrumentData(instrument: entry.instrument)]
        .totalInvested += entry.amount
    }
    for event in ledger.realisedEvents where !unavailable.contains(event.instrument.id) {
      instrumentData[event.instrument.id, default: InstrumentData(instrument: event.instrument)]
        .realizedGain += event.gain
    }
    for lot in ledger.openLots where !unavailable.contains(lot.instrument.id) {
      let id = lot.instrument.id
      instrumentData[id, default: InstrumentData(instrument: lot.instrument)]
        .currentQuantity += lot.remainingQuantity
      instrumentData[id, default: InstrumentData(instrument: lot.instrument)]
        .remainingCostBasis += lot.remainingCost
    }

    let projection = try await buildResults(
      from: instrumentData,
      profileCurrency: profileCurrency,
      conversionService: conversionService,
      asOfDate: asOfDate)
    return ProfitLossResult(
      rows: projection.rows,
      unavailableInstrumentIds: unavailable.union(projection.unavailableInstrumentIds),
      unavailableInstruments: ledger.unavailableInstruments.union(projection.unavailableInstruments)
    )
  }

  private static func buildResults(
    from instrumentData: [String: InstrumentData],
    profileCurrency: Instrument,
    conversionService: InstrumentConversionService,
    asOfDate: Date
  ) async throws -> ProjectionResult {
    var results: [InstrumentProfitLoss] = []
    var unavailableInstrumentIds: Set<String> = []
    var unavailableInstruments: Set<Instrument> = []
    for (_, data) in instrumentData {
      var currentValue: Decimal = 0
      if data.currentQuantity > 0 {
        do {
          let result = try await conversionService.convertResult(
            InstrumentAmount(quantity: data.currentQuantity, instrument: data.instrument),
            to: profileCurrency,
            on: asOfDate)
          switch result {
          case .value(let amount):
            currentValue = amount.quantity
          case .knownZero:
            currentValue = 0
          }
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          logger.error(
            "Current-value conversion failed for \(data.instrument.id, privacy: .public): \(error)"
          )
          unavailableInstrumentIds.insert(data.instrument.id)
          unavailableInstruments.insert(data.instrument)
          continue
        }
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
    return ProjectionResult(
      rows: results.sorted { $0.totalGain > $1.totalGain },
      unavailableInstrumentIds: unavailableInstrumentIds,
      unavailableInstruments: unavailableInstruments)
  }

  private struct ProjectionResult {
    let rows: [InstrumentProfitLoss]
    let unavailableInstrumentIds: Set<String>
    let unavailableInstruments: Set<Instrument>
  }

  private struct InstrumentData {
    let instrument: Instrument
    var totalInvested: Decimal = 0
    var realizedGain: Decimal = 0
    var currentQuantity: Decimal = 0
    var remainingCostBasis: Decimal = 0
  }
}

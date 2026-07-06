import Foundation

/// Input type: a transaction's legs with its date.
struct LegTransaction: Sendable {
  let date: Date
  let legs: [TransactionLeg]
}

/// Result of capital gains computation over a set of transactions.
struct CapitalGainsResult: Sendable {
  let events: [CapitalGainEvent]
  let openLots: [CostBasisLot]
  /// `true` when at least one instrument's cost-basis history hit an
  /// unresolvable conversion during the ledger build (Rule 11), so a disposal
  /// may have been dropped and the realised-gain total may be understated. A
  /// coarse profile-wide flag: the caller must render the figure as
  /// unavailable rather than as a complete tax number. Defaults to `false` for
  /// the direct-construction / fixture call sites that never fail conversion.
  let hasUnavailableData: Bool

  init(
    events: [CapitalGainEvent], openLots: [CostBasisLot], hasUnavailableData: Bool = false
  ) {
    self.events = events
    self.openLots = openLots
    self.hasUnavailableData = hasUnavailableData
  }

  var totalRealizedGain: Decimal {
    events.reduce(Decimal(0)) { $0 + $1.gain }
  }

  var shortTermGain: Decimal {
    events.filter { !$0.isLongTerm }.reduce(Decimal(0)) { $0 + $1.gain }
  }

  var longTermGain: Decimal {
    events.filter { $0.isLongTerm }.reduce(Decimal(0)) { $0 + $1.gain }
  }
}

/// Processes transaction legs to extract buy/sell events and compute capital gains.
///
/// **Buy detection:** A non-fiat instrument leg with positive quantity, paired with a
/// fiat outflow leg in the same transaction. Cost per unit = fiat amount / quantity.
///
/// **Sell detection:** A non-fiat instrument leg with negative quantity, paired with a
/// fiat inflow leg. Proceeds per unit = fiat amount / quantity.
///
/// **Crypto-to-crypto swaps:** Both legs are non-fiat. Requires conversion service to
/// determine AUD-equivalent proceeds. Use `computeWithConversion` for these cases.
///
/// Leg classification is delegated to `TradeEventClassifier`, which is the single
/// source of truth for buy/sell classification across the entire codebase.
enum CapitalGainsCalculator {

  /// Pure realised-CGT projection from a pre-built profile-wide ledger.
  /// `ReportingStore` passes the shared `HoldingsCostLedgerStore` ledger so
  /// the tax path does not rebuild it. The ledger already realises the full
  /// disposal set — sells, crypto spends / gas (non-fiat `.expense`), and
  /// income/opening-funded lots — against market-value cost bases; a
  /// tracked→tracked transfer is a non-event (the lot's cost carries), so it
  /// never appears here.
  static func compute(
    ledger: HoldingsCostLedger, sellDateRange: ClosedRange<Date>? = nil
  ) -> CapitalGainsResult {
    let events = ledger.realisedEvents.filter { event in
      sellDateRange.map { $0.contains(event.sellDate) } ?? true
    }
    return CapitalGainsResult(
      events: events,
      openLots: ledger.openLots,
      hasUnavailableData: !ledger.unavailableInstrumentIds.isEmpty)
  }

  /// Retained convenience for unit-test call sites: builds a profile-wide
  /// ledger from `LegTransaction`s then projects. Production (`ReportingStore`)
  /// uses `compute(ledger:)` with the shared `HoldingsCostLedgerStore` ledger
  /// so the build is not repeated. Now that the ledger drives realisation,
  /// income/opening-funded lots and crypto spends realise here too — not only
  /// fiat-paired `.trade`s — matching the profile-wide model.
  static func computeWithConversion(
    transactions: [LegTransaction],
    profileCurrency: Instrument,
    conversionService: any InstrumentConversionService,
    sellDateRange: ClosedRange<Date>? = nil
  ) async throws -> CapitalGainsResult {
    let txns = transactions.map { Transaction(date: $0.date, legs: $0.legs) }
    let ledger = try await HoldingsCostLedger.build(
      transactions: txns,
      referenceCurrency: profileCurrency,
      conversionService: conversionService)
    return compute(ledger: ledger, sellDateRange: sellDateRange)
  }
}

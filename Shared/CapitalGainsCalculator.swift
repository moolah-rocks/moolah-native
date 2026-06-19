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

  /// Compute capital gains including non-fiat swaps, using conversion service for AUD-equivalent.
  static func computeWithConversion(
    transactions: [LegTransaction],
    profileCurrency: Instrument,
    conversionService: any InstrumentConversionService,
    sellDateRange: ClosedRange<Date>? = nil
  ) async throws -> CapitalGainsResult {
    var engine = CostBasisEngine()
    var allEvents: [CapitalGainEvent] = []
    let sorted = transactions.sorted { $0.date < $1.date }

    for transaction in sorted {
      let classification = try await TradeEventClassifier.classify(
        legs: transaction.legs,
        on: transaction.date,
        hostCurrency: profileCurrency,
        conversionService: conversionService
      )
      for buy in classification.buys {
        engine.processBuy(
          instrument: buy.instrument,
          quantity: buy.quantity,
          costPerUnit: buy.costPerUnit,
          date: transaction.date)
      }
      for sell in classification.sells {
        let inRange = sellDateRange.map { $0.contains(transaction.date) } ?? true
        let events = engine.processSell(
          instrument: sell.instrument,
          quantity: sell.quantity,
          proceedsPerUnit: sell.proceedsPerUnit,
          date: transaction.date)
        if inRange { allEvents.append(contentsOf: events) }
      }
    }
    return CapitalGainsResult(events: allEvents, openLots: engine.allOpenLots())
  }
}

import Foundation

/// Maps one transaction's legs to `CostBasisEvent`s, each valued in AUD
/// on `date`. `.trade` legs reuse `TradeEventClassifier` verbatim (buy →
/// acquisition, sell → disposal, fees folded into per-unit). Non-fiat
/// `.income`/`.openingBalance` → acquisition at market value; tracked→tracked
/// `.transfer` → move (cost carries in the engine, market value recorded for
/// return); non-fiat `.expense` → disposal at market value (crypto spend /
/// gas). Fiat legs that are not attached trade fees are non-events.
enum CostBasisEventBuilder {
  static func events(
    legs: [TransactionLeg],
    on date: Date,
    trackedAccountIds: Set<UUID>,
    referenceCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> [CostBasisEvent] {
    var events: [CostBasisEvent] = []
    // 1. `.trade` legs → classifier (fees already folded into per-unit).
    events.append(
      contentsOf: try await tradeEvents(
        legs: legs,
        on: date,
        referenceCurrency: referenceCurrency,
        conversionService: conversionService))
    // 2. Non-fiat `.income` / `.openingBalance` → acquisition @ market value.
    events.append(
      contentsOf: try await nonFiatAcquisitions(
        legs: legs,
        on: date,
        referenceCurrency: referenceCurrency,
        conversionService: conversionService))
    // 3. Non-fiat `.expense` (gas / spend / send-out) → disposal @ market value.
    events.append(
      contentsOf: try await nonFiatDisposals(
        legs: legs,
        on: date,
        referenceCurrency: referenceCurrency,
        conversionService: conversionService))
    // 4. Tracked→tracked `.transfer` → move (cost carries; market value for return).
    events.append(
      contentsOf: try await transferMoves(
        legs: legs,
        on: date,
        trackedAccountIds: trackedAccountIds,
        referenceCurrency: referenceCurrency,
        conversionService: conversionService))
    return events
  }

  /// `.trade` legs delegate to `TradeEventClassifier`: buys → acquisitions,
  /// sells → disposals, attached fees already folded into per-unit values.
  private static func tradeEvents(
    legs: [TransactionLeg],
    on date: Date,
    referenceCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> [CostBasisEvent] {
    let classification = try await TradeEventClassifier.classify(
      legs: legs, on: date, hostCurrency: referenceCurrency, conversionService: conversionService)
    var events: [CostBasisEvent] = []
    for buy in classification.buys {
      events.append(
        .acquisition(
          instrument: buy.instrument,
          quantity: buy.quantity,
          costPerUnit: buy.costPerUnit,
          account: accountFor(buy.instrument, in: legs)))
    }
    for sell in classification.sells {
      events.append(
        .disposal(
          instrument: sell.instrument,
          quantity: sell.quantity,
          proceedsPerUnit: sell.proceedsPerUnit,
          account: accountFor(sell.instrument, in: legs)))
    }
    return events
  }

  /// Non-fiat `.income` / `.openingBalance` legs enter holdings at their
  /// market value on `date` (cost basis = value received).
  private static func nonFiatAcquisitions(
    legs: [TransactionLeg],
    on date: Date,
    referenceCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> [CostBasisEvent] {
    var events: [CostBasisEvent] = []
    for leg in legs
    where leg.instrument.kind != .fiatCurrency
      && (leg.type == .income || leg.type == .openingBalance) && leg.quantity > 0
    {
      let value = try await marketValue(
        leg.quantity,
        of: leg.instrument,
        on: date,
        in: referenceCurrency,
        using: conversionService)
      events.append(
        .acquisition(
          instrument: leg.instrument,
          quantity: leg.quantity,
          costPerUnit: value / leg.quantity,
          account: leg.accountId))
    }
    return events
  }

  /// Non-fiat `.expense` legs (crypto spend / gas / send-out) leave holdings,
  /// realising proceeds at their market value on `date`.
  private static func nonFiatDisposals(
    legs: [TransactionLeg],
    on date: Date,
    referenceCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> [CostBasisEvent] {
    var events: [CostBasisEvent] = []
    for leg in legs
    where leg.instrument.kind != .fiatCurrency && leg.type == .expense && leg.quantity < 0 {
      let qty = -leg.quantity
      let value = try await marketValue(
        qty,
        of: leg.instrument,
        on: date,
        in: referenceCurrency,
        using: conversionService)
      events.append(
        .disposal(
          instrument: leg.instrument,
          quantity: qty,
          proceedsPerUnit: value / qty,
          account: leg.accountId))
    }
    return events
  }

  /// A transfer transaction has a negative (source) and positive (dest)
  /// `.transfer` leg of the same instrument, both tracked. Value the move
  /// at the destination quantity's market value on `date`.
  private static func transferMoves(
    legs: [TransactionLeg],
    on date: Date,
    trackedAccountIds: Set<UUID>,
    referenceCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> [CostBasisEvent] {
    let transfers = legs.filter { $0.type == .transfer && $0.instrument.kind != .fiatCurrency }
    guard let source = transfers.first(where: { $0.quantity < 0 }),
      let dest = transfers.first(where: { $0.quantity > 0 }),
      source.instrument == dest.instrument,
      let from = source.accountId, let to = dest.accountId,
      trackedAccountIds.contains(from), trackedAccountIds.contains(to)
    else { return [] }
    let qty = dest.quantity
    let market = try await marketValue(
      qty, of: dest.instrument, on: date, in: referenceCurrency, using: conversionService)
    return [
      .move(instrument: dest.instrument, quantity: qty, from: from, to: to, marketValue: market)
    ]
  }

  private static func marketValue(
    _ quantity: Decimal,
    of instrument: Instrument,
    on date: Date,
    in referenceCurrency: Instrument,
    using service: any InstrumentConversionService
  ) async throws -> Decimal {
    if instrument == referenceCurrency { return quantity }
    return try await service.convert(quantity, from: instrument, to: referenceCurrency, on: date)
  }

  private static func accountFor(_ instrument: Instrument, in legs: [TransactionLeg]) -> UUID? {
    legs.first { $0.instrument == instrument && $0.type == .trade }?.accountId
  }
}

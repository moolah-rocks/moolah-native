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
    sourceTransactionId: UUID? = nil,
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
        sourceTransactionId: sourceTransactionId,
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
        sourceTransactionId: sourceTransactionId,
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
    sourceTransactionId: UUID?,
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
          account: accountFor(sell.instrument, in: legs),
          sourceTransactionId: sourceTransactionId))
    }
    return events
  }

  /// Non-fiat legs that *enter* holdings at their market value on `date` (cost
  /// basis = value received): `.income` / `.openingBalance`, plus a positive
  /// non-fiat `.expense` — a refund (sign convention lets any type carry the
  /// opposite sign; CODE_GUIDE §16), the mirror of the negative-expense
  /// disposal in `nonFiatDisposals`.
  private static func nonFiatAcquisitions(
    legs: [TransactionLeg],
    on date: Date,
    referenceCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> [CostBasisEvent] {
    var events: [CostBasisEvent] = []
    for leg in legs
    where leg.instrument.kind != .fiatCurrency
      && (leg.type == .income || leg.type == .openingBalance || leg.type == .expense)
      && leg.quantity > 0
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
    sourceTransactionId: UUID?,
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
          account: leg.accountId,
          sourceTransactionId: sourceTransactionId))
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

  /// Market value of `quantity` of `instrument` in `referenceCurrency` on
  /// `date`. Uses the discriminated `convertResult` so an intentional zero
  /// (an `.unpriced` / `.spam` token — a common airdrop `.income` leg)
  /// values at `0` rather than throwing: a valid amount-invested of 0. A
  /// genuine provider failure still throws, so the caller's per-transaction
  /// isolation (`HoldingsCostLedger.runPass`) can degrade only the affected
  /// `(account, instrument)` keys per Rule 11.
  private static func marketValue(
    _ quantity: Decimal,
    of instrument: Instrument,
    on date: Date,
    in referenceCurrency: Instrument,
    using service: any InstrumentConversionService
  ) async throws -> Decimal {
    if instrument == referenceCurrency { return quantity }
    let result = try await service.convertResult(
      InstrumentAmount(quantity: quantity, instrument: instrument),
      to: referenceCurrency,
      on: date)
    switch result {
    case .value(let converted): return converted.quantity
    case .knownZero: return 0
    }
  }

  private static func accountFor(_ instrument: Instrument, in legs: [TransactionLeg]) -> UUID? {
    legs.first { $0.instrument == instrument && $0.type == .trade }?.accountId
  }
}

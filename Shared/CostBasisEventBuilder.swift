import Foundation

/// Maps one transaction's legs to `CostBasisEvent`s, each valued in AUD
/// on `date`. `.trade` legs reuse `TradeEventClassifier` verbatim (buy →
/// acquisition, sell → disposal, fees folded into per-unit). Non-fiat
/// `.income`/`.openingBalance` → acquisition at market value; tracked→tracked
/// `.transfer` → move (cost carries in the engine, market value recorded for
/// return); non-fiat `.expense` → disposal at market value (crypto spend /
/// gas). Fiat legs that are not attached trade fees are non-events.
enum CostBasisEventBuilder {
  private struct BuildInput {
    let sourceTransactionId: UUID?
    let legs: [TransactionLeg]
    let date: Date
    let trackedAccountIds: Set<UUID>
    let referenceCurrency: Instrument
    let conversionService: any InstrumentConversionService
    let taxOwnerIdsByAccount: [UUID?: [UUID]]
  }

  static func events(
    sourceTransactionId: UUID? = nil,
    legs: [TransactionLeg],
    on date: Date,
    trackedAccountIds: Set<UUID>,
    referenceCurrency: Instrument,
    conversionService: any InstrumentConversionService,
    taxOwnerIdsByAccount: [UUID?: [UUID]] = [:]
  ) async throws -> [CostBasisEvent] {
    let input = BuildInput(
      sourceTransactionId: sourceTransactionId,
      legs: legs,
      date: date,
      trackedAccountIds: trackedAccountIds,
      referenceCurrency: referenceCurrency,
      conversionService: conversionService,
      taxOwnerIdsByAccount: taxOwnerIdsByAccount)

    var events: [CostBasisEvent] = []
    // 1. `.trade` legs → classifier (fees already folded into per-unit).
    events.append(contentsOf: try await tradeEvents(input))
    // 2. Non-fiat `.income` / `.openingBalance` → acquisition @ market value.
    events.append(contentsOf: try await nonFiatAcquisitions(input))
    // 3. Non-fiat `.expense` (gas / spend / send-out) → disposal @ market value.
    events.append(contentsOf: try await nonFiatDisposals(input))
    // 4. Tracked→tracked `.transfer` → move (cost carries; market value for return).
    events.append(contentsOf: try await transferMoves(input))
    return events
  }

  /// `.trade` legs delegate to `TradeEventClassifier`: buys → acquisitions,
  /// sells → disposals, attached fees already folded into per-unit values.
  private static func tradeEvents(_ input: BuildInput) async throws -> [CostBasisEvent] {
    let classification = try await TradeEventClassifier.classify(
      legs: input.legs,
      on: input.date,
      hostCurrency: input.referenceCurrency,
      conversionService: input.conversionService)
    var events: [CostBasisEvent] = []
    for buy in classification.buys {
      let account = accountFor(buy.instrument, in: input.legs)
      for allocation in ownerAllocations(account: account, in: input.taxOwnerIdsByAccount) {
        events.append(
          .acquisition(
            instrument: buy.instrument,
            quantity: buy.quantity * allocation.fraction,
            costPerUnit: buy.costPerUnit,
            holding: holding(account: account, allocation: allocation)))
      }
    }
    for sell in classification.sells {
      let account = accountFor(sell.instrument, in: input.legs)
      for allocation in ownerAllocations(account: account, in: input.taxOwnerIdsByAccount) {
        events.append(
          .disposal(
            instrument: sell.instrument,
            quantity: sell.quantity * allocation.fraction,
            proceedsPerUnit: sell.proceedsPerUnit,
            context: disposalContext(
              account: account,
              allocation: allocation,
              sourceTransactionId: input.sourceTransactionId)))
      }
    }
    return events
  }

  /// Non-fiat legs that *enter* holdings at their market value on `date` (cost
  /// basis = value received): `.income` / `.openingBalance`, plus a positive
  /// non-fiat `.expense` — a refund (sign convention lets any type carry the
  /// opposite sign; CODE_GUIDE §16), the mirror of the negative-expense
  /// disposal in `nonFiatDisposals`.
  private static func nonFiatAcquisitions(_ input: BuildInput) async throws -> [CostBasisEvent] {
    var events: [CostBasisEvent] = []
    for leg in input.legs
    where leg.instrument.kind != .fiatCurrency
      && (leg.type == .income || leg.type == .openingBalance || leg.type == .expense)
      && leg.quantity > 0
    {
      let value = try await marketValue(
        leg.quantity,
        of: leg.instrument,
        on: input.date,
        in: input.referenceCurrency,
        using: input.conversionService)
      for allocation in ownerAllocations(account: leg.accountId, in: input.taxOwnerIdsByAccount) {
        events.append(
          .acquisition(
            instrument: leg.instrument,
            quantity: leg.quantity * allocation.fraction,
            costPerUnit: value / leg.quantity,
            holding: holding(account: leg.accountId, allocation: allocation)))
      }
    }
    return events
  }

  /// Non-fiat `.expense` legs (crypto spend / gas / send-out) leave holdings,
  /// realising proceeds at their market value on `date`.
  private static func nonFiatDisposals(_ input: BuildInput) async throws -> [CostBasisEvent] {
    var events: [CostBasisEvent] = []
    for leg in input.legs
    where leg.instrument.kind != .fiatCurrency && leg.type == .expense && leg.quantity < 0 {
      let qty = -leg.quantity
      let value = try await marketValue(
        qty,
        of: leg.instrument,
        on: input.date,
        in: input.referenceCurrency,
        using: input.conversionService)
      for allocation in ownerAllocations(account: leg.accountId, in: input.taxOwnerIdsByAccount) {
        events.append(
          .disposal(
            instrument: leg.instrument,
            quantity: qty * allocation.fraction,
            proceedsPerUnit: value / qty,
            context: disposalContext(
              account: leg.accountId,
              allocation: allocation,
              sourceTransactionId: input.sourceTransactionId)))
      }
    }
    return events
  }

  /// A transfer transaction has a negative (source) and positive (dest)
  /// `.transfer` leg of the same instrument, both tracked. Value the move
  /// at the destination quantity's market value on `date`.
  private static func transferMoves(_ input: BuildInput) async throws -> [CostBasisEvent] {
    let transfers = input.legs.filter {
      $0.type == .transfer && $0.instrument.kind != .fiatCurrency
    }
    guard let source = transfers.first(where: { $0.quantity < 0 }),
      let dest = transfers.first(where: { $0.quantity > 0 }),
      source.instrument == dest.instrument,
      let from = source.accountId, let to = dest.accountId,
      input.trackedAccountIds.contains(from), input.trackedAccountIds.contains(to)
    else { return [] }
    let qty = dest.quantity
    let market = try await marketValue(
      qty,
      of: dest.instrument,
      on: input.date,
      in: input.referenceCurrency,
      using: input.conversionService)
    return ownerAllocations(account: from, in: input.taxOwnerIdsByAccount).map { allocation in
      .move(
        instrument: dest.instrument,
        quantity: qty * allocation.fraction,
        route: CostBasisMoveRoute(from: from, to: to, taxOwnerId: allocation.taxOwnerId),
        marketValue: market * allocation.fraction)
    }
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

  private struct OwnerAllocation {
    let taxOwnerId: UUID?
    let fraction: Decimal
  }

  private static func holding(
    account: UUID?, allocation: OwnerAllocation
  ) -> CostBasisEventHolding {
    CostBasisEventHolding(account: account, taxOwnerId: allocation.taxOwnerId)
  }

  private static func disposalContext(
    account: UUID?,
    allocation: OwnerAllocation,
    sourceTransactionId: UUID?
  ) -> CostBasisDisposalContext {
    CostBasisDisposalContext(
      holding: holding(account: account, allocation: allocation),
      sourceTransactionId: sourceTransactionId)
  }

  private static func ownerAllocations(
    account: UUID?,
    in taxOwnerIdsByAccount: [UUID?: [UUID]]
  ) -> [OwnerAllocation] {
    let ownerIds = taxOwnerIdsByAccount[account] ?? []
    guard !ownerIds.isEmpty else {
      return [OwnerAllocation(taxOwnerId: nil, fraction: 1)]
    }
    let fraction = Decimal(1) / Decimal(ownerIds.count)
    return ownerIds.map { OwnerAllocation(taxOwnerId: $0, fraction: fraction) }
  }

  private static func accountFor(_ instrument: Instrument, in legs: [TransactionLeg]) -> UUID? {
    legs.first { $0.instrument == instrument && $0.type == .trade }?.accountId
  }
}

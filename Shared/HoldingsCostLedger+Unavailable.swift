import Foundation
import OSLog

private let holdingsCostLedgerUnavailableLogger = Logger(
  subsystem: "com.moolah.app", category: "HoldingsCostLedger")

extension HoldingsCostLedger {
  static func applyEvents(
    _ events: [CostBasisEvent],
    to pass: inout HoldingsCostLedgerPass,
    on date: Date
  ) -> [InvestedSnapshot] {
    var touched: Set<TouchKey> = []
    for event in orderedEvents(events) {
      pass.apply(event, on: date)
      touched.formUnion(touchedKeys(for: event))
    }
    return investedSnapshots(for: touched, on: date, pass: pass)
  }

  static func investedSnapshots(
    for keys: Set<TouchKey>,
    on date: Date,
    pass: HoldingsCostLedgerPass
  ) -> [InvestedSnapshot] {
    keys.map { key in
      let invested =
        pass.engine
        .openLots(for: key.instrument, account: key.account, taxOwnerId: key.taxOwnerId)
        .reduce(Decimal(0)) { $0 + $1.remainingCost }
      return InvestedSnapshot(
        date: date,
        account: key.account,
        instrument: key.instrument,
        taxOwnerId: key.taxOwnerId,
        remainingInvested: invested)
    }
  }

  static func realisedGainDisposalCandidates(
    in group: TransactionGroup
  ) -> Set<HoldingsCostLedgerDisposalCandidate> {
    let directDisposals = group.legs.flatMap { leg -> [HoldingsCostLedgerDisposalCandidate] in
      guard leg.instrument.kind != .fiatCurrency else { return [] }
      guard
        (leg.type == .trade && leg.quantity < 0)
          || (leg.type == .expense && leg.quantity < 0)
      else { return [] }
      return touchKeys(account: leg.accountId, instrument: leg.instrument, in: group).map { key in
        HoldingsCostLedgerDisposalCandidate(date: group.date, key: key)
      }
    }
    let transferDisposals = transferDisposalCandidateKeys(in: group).map { key in
      HoldingsCostLedgerDisposalCandidate(date: group.date, key: key)
    }
    return Set(directDisposals + transferDisposals)
  }

  static func realisedGainMoveCandidates(
    in group: TransactionGroup
  ) -> Set<HoldingsCostLedgerMoveCandidate> {
    let transfers = group.legs.filter {
      $0.type == .transfer && $0.instrument.kind != .fiatCurrency
    }
    guard let source = transfers.first(where: { $0.quantity < 0 }),
      let destination = transfers.first(where: { $0.quantity > 0 }),
      source.instrument == destination.instrument
    else { return [] }
    let sourceKeys = touchKeys(account: source.accountId, instrument: source.instrument, in: group)
    return Set(
      sourceKeys.map { sourceKey in
        HoldingsCostLedgerMoveCandidate(
          date: group.date,
          source: sourceKey,
          destination: TouchKey(
            account: destination.accountId,
            instrument: destination.instrument,
            taxOwnerId: sourceKey.taxOwnerId))
      })
  }

  static func recordUnavailableInput(
    for group: TransactionGroup,
    error: Error,
    unavailable: inout Set<TouchKey>,
    inputs: inout Set<HoldingsCostLedgerUnavailableInput>
  ) {
    let keys = nonFiatKeys(in: group)
    unavailable.formUnion(keys)
    holdingsCostLedgerUnavailableLogger.error(
      "Cost-basis conversion failed for transaction \(group.id, privacy: .public) on \(group.date, privacy: .public): \(error.localizedDescription, privacy: .public)"
    )
    if mayEmitDirectDisposal(in: group) {
      inputs.insert(
        HoldingsCostLedgerUnavailableInput(
          date: group.date,
          keys: Set(keys),
          mayAffectRealisedGains: true))
      return
    }

    inputs.insert(
      HoldingsCostLedgerUnavailableInput(
        date: group.date,
        keys: Set(keys),
        mayAffectRealisedGains: false))
    let transferDisposalKeys = Set(transferDisposalCandidateKeys(in: group))
    if !transferDisposalKeys.isEmpty {
      inputs.insert(
        HoldingsCostLedgerUnavailableInput(
          date: group.date,
          keys: transferDisposalKeys,
          mayAffectRealisedGains: true))
    }
  }

  static func recordTransferMarketValueFailure(
    _ error: CostBasisTransferEventBuilder.MarketValueFailure,
    for group: TransactionGroup,
    unavailable: inout Set<TouchKey>,
    inputs: inout Set<HoldingsCostLedgerUnavailableInput>
  ) {
    guard
      let instrument = group.legs.first(where: {
        $0.type == .transfer && $0.instrument.kind != .fiatCurrency
      })?.instrument
    else { return }
    let sourceKeys = Set(
      error.sourceDisposalHoldings.map {
        TouchKey(account: $0.account, instrument: instrument, taxOwnerId: $0.taxOwnerId)
      })
    let destinationKeys = Set(
      error.destinationAcquisitionHoldings.map {
        TouchKey(account: $0.account, instrument: instrument, taxOwnerId: $0.taxOwnerId)
      })
    unavailable.formUnion(sourceKeys)
    unavailable.formUnion(destinationKeys)
    holdingsCostLedgerUnavailableLogger.error(
      "Cost-basis transfer market value failed for transaction \(group.id, privacy: .public) on \(group.date, privacy: .public): \(error.underlyingError.localizedDescription, privacy: .public)"
    )
    if !destinationKeys.isEmpty {
      inputs.insert(
        HoldingsCostLedgerUnavailableInput(
          date: group.date,
          keys: destinationKeys,
          mayAffectRealisedGains: false))
    }
    if !sourceKeys.isEmpty {
      inputs.insert(
        HoldingsCostLedgerUnavailableInput(
          date: group.date,
          keys: sourceKeys,
          mayAffectRealisedGains: true))
    }
  }

  static func touchedKeys(for event: CostBasisEvent) -> [TouchKey] {
    switch event {
    case let .disposal(instrument, _, _, context):
      return [
        TouchKey(
          account: context.holding.account,
          instrument: instrument,
          taxOwnerId: context.holding.taxOwnerId)
      ]
    case let .move(instrument, _, route, _):
      return [
        TouchKey(account: route.from, instrument: instrument, taxOwnerId: route.taxOwnerId),
        TouchKey(account: route.to, instrument: instrument, taxOwnerId: route.taxOwnerId),
      ]
    case let .acquisition(instrument, _, _, holding):
      return [
        TouchKey(account: holding.account, instrument: instrument, taxOwnerId: holding.taxOwnerId)
      ]
    }
  }

  struct TouchKey: Hashable {
    let account: UUID?
    let instrument: Instrument
    let taxOwnerId: UUID?
  }

  private static func nonFiatKeys(in group: TransactionGroup) -> [TouchKey] {
    group.legs
      .filter { $0.instrument.kind != .fiatCurrency }
      .flatMap { touchKeys(account: $0.accountId, instrument: $0.instrument, in: group) }
  }

  private static func mayEmitDirectDisposal(in group: TransactionGroup) -> Bool {
    group.legs.contains { leg in
      leg.instrument.kind != .fiatCurrency
        && ((leg.type == .trade && leg.quantity < 0)
          || (leg.type == .expense && leg.quantity < 0))
    }
  }

  private static func transferDisposalCandidateKeys(in group: TransactionGroup) -> [TouchKey] {
    let transfers = group.legs.filter {
      $0.type == .transfer && $0.instrument.kind != .fiatCurrency
    }
    guard let source = transfers.first(where: { $0.quantity < 0 }),
      let destination = transfers.first(where: { $0.quantity > 0 }),
      source.instrument == destination.instrument
    else { return [] }
    let destinationFractions = ownerFractions(
      account: destination.accountId,
      instrument: destination.instrument,
      in: group)
    return ownerFractions(account: source.accountId, instrument: source.instrument, in: group)
      .filter { owner, fraction in
        fraction > (destinationFractions[owner] ?? 0)
      }
      .map { owner, _ in
        TouchKey(account: source.accountId, instrument: source.instrument, taxOwnerId: owner)
      }
  }

  private static func ownerFractions(
    account: UUID?,
    instrument: Instrument,
    in group: TransactionGroup
  ) -> [UUID?: Decimal] {
    let keys = touchKeys(account: account, instrument: instrument, in: group)
    let fraction = Decimal(1) / Decimal(keys.count)
    return Dictionary(uniqueKeysWithValues: keys.map { ($0.taxOwnerId, fraction) })
  }

  private static func touchKeys(
    account: UUID?,
    instrument: Instrument,
    in group: TransactionGroup
  ) -> [TouchKey] {
    let ownerIds = group.taxOwnerIdsByAccount[account] ?? []
    guard !ownerIds.isEmpty else {
      return [TouchKey(account: account, instrument: instrument, taxOwnerId: nil)]
    }
    return ownerIds.map { TouchKey(account: account, instrument: instrument, taxOwnerId: $0) }
  }
}

import Foundation

extension HoldingsCostLedger {
  static var empty: HoldingsCostLedger {
    HoldingsCostLedger(
      investedSnapshots: [],
      realisedEvents: [],
      flows: [],
      openLots: [],
      unavailableKeys: [],
      unavailableInputs: [],
      disposalCandidates: [],
      moveCandidates: [])
  }

  var unavailableInstrumentIds: Set<String> {
    Set(unavailableInstruments.map(\.id))
  }

  var unavailableInstruments: Set<Instrument> {
    unavailableInstruments(ownerId: nil)
  }

  func unavailableInstruments(ownerId: UUID?) -> Set<Instrument> {
    Set(unavailableKeys(ownerId: ownerId).map(\.instrument))
  }

  func unavailableRealisedGainInstruments(
    in interval: Range<Date>,
    ownerId: UUID? = nil
  ) -> Set<Instrument> {
    unavailableInputs(ownerId: ownerId).realisedGainInstruments(
      in: interval,
      disposalCandidates: disposalCandidates(ownerId: ownerId),
      moveCandidates: moveCandidates(ownerId: ownerId))
  }

  func remainingInvested(accountIds: Set<UUID>, onOrBefore day: Date) -> Decimal? {
    guard !hasUnavailable(accountIds: accountIds, instrument: nil) else { return nil }
    return latestLevels(accountIds: accountIds, instrumentId: nil, onOrBefore: day)
  }

  func remainingInvested(
    accountIds: Set<UUID>, instrument: Instrument, onOrBefore day: Date
  ) -> Decimal? {
    guard !hasUnavailable(accountIds: accountIds, instrument: instrument) else { return nil }
    return latestLevels(accountIds: accountIds, instrumentId: instrument.id, onOrBefore: day)
  }

  func cashFlows(accountIds: Set<UUID>) -> [CashFlow] {
    flows
      .filter { entry in
        guard let account = entry.account, accountIds.contains(account) else { return false }
        if let counterparty = entry.counterpartyAccount, accountIds.contains(counterparty) {
          return false
        }
        return true
      }
      .sorted { $0.date < $1.date }
      .map { CashFlow(date: $0.date, amount: $0.amount) }
  }

  private func unavailableKeys(ownerId: UUID?) -> Set<TouchKey> {
    guard let ownerId else { return unavailableKeys }
    return unavailableKeys.filter { $0.taxOwnerId == ownerId }
  }

  private func unavailableInputs(ownerId: UUID?) -> Set<HoldingsCostLedgerUnavailableInput> {
    guard let ownerId else { return unavailableInputs }
    return Set(
      unavailableInputs.compactMap { input in
        let keys = input.keys.filter { $0.taxOwnerId == ownerId }
        guard !keys.isEmpty else { return nil }
        return HoldingsCostLedgerUnavailableInput(
          date: input.date,
          keys: Set(keys),
          mayAffectRealisedGains: input.mayAffectRealisedGains)
      })
  }

  private func disposalCandidates(
    ownerId: UUID?
  ) -> Set<HoldingsCostLedgerDisposalCandidate> {
    guard let ownerId else { return disposalCandidates }
    return disposalCandidates.filter { $0.key.taxOwnerId == ownerId }
  }

  private func moveCandidates(
    ownerId: UUID?
  ) -> Set<HoldingsCostLedgerMoveCandidate> {
    guard let ownerId else { return moveCandidates }
    return moveCandidates.filter {
      $0.source.taxOwnerId == ownerId || $0.destination.taxOwnerId == ownerId
    }
  }

  private func hasUnavailable(accountIds: Set<UUID>, instrument: Instrument?) -> Bool {
    unavailableKeys.contains { key in
      guard let account = key.account, accountIds.contains(account) else { return false }
      if let instrument, key.instrument != instrument { return false }
      return true
    }
  }

  private func latestLevels(
    accountIds: Set<UUID>, instrumentId: String?, onOrBefore day: Date
  ) -> Decimal {
    struct Key: Hashable {
      let account: UUID?
      let instrumentId: String
      let taxOwnerId: UUID?
    }
    var latest: [Key: (day: Date, value: Decimal)] = [:]
    for snap in investedSnapshots {
      guard let account = snap.account, accountIds.contains(account) else { continue }
      if let want = instrumentId, snap.instrument.id != want { continue }
      let snapDay = Calendar.utc.startOfDay(for: snap.date)
      guard snapDay <= day else { continue }
      let key = Key(account: account, instrumentId: snap.instrument.id, taxOwnerId: snap.taxOwnerId)
      if let existing = latest[key], existing.day > snapDay { continue }
      latest[key] = (snapDay, snap.remainingInvested)
    }
    return latest.values.reduce(Decimal(0)) { $0 + $1.value }
  }
}

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
    Set(unavailableKeys.map(\.instrument.id))
  }

  var unavailableInstruments: Set<Instrument> {
    Set(unavailableKeys.map(\.instrument))
  }

  func unavailableRealisedGainInstruments(in interval: Range<Date>) -> Set<Instrument> {
    unavailableInputs.realisedGainInstruments(
      in: interval,
      disposalCandidates: disposalCandidates,
      moveCandidates: moveCandidates)
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
    }
    var latest: [Key: (day: Date, value: Decimal)] = [:]
    for snap in investedSnapshots {
      guard let account = snap.account, accountIds.contains(account) else { continue }
      if let want = instrumentId, snap.instrument.id != want { continue }
      let snapDay = Calendar.utc.startOfDay(for: snap.date)
      guard snapDay <= day else { continue }
      let key = Key(account: account, instrumentId: snap.instrument.id)
      if let existing = latest[key], existing.day > snapDay { continue }
      latest[key] = (snapDay, snap.remainingInvested)
    }
    return latest.values.reduce(Decimal(0)) { $0 + $1.value }
  }
}

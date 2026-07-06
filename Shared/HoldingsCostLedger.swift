import Foundation

/// Profile-global cost pass. Groups the SQL-reduced key-event legs back
/// into per-transaction inputs, warms the needed `(instrument, day)` rates
/// in one batch, then runs `CostBasisEventBuilder` in date order through
/// one account-aware `CostBasisEngine`, producing the shared outputs every
/// consumer reads: per-(account, instrument) remaining-amount-invested
/// change-points (baseline), realised `CapitalGainEvent`s (tax), open lots,
/// and market-valued flows (return).
struct HoldingsCostLedger: Sendable {
  let investedSnapshots: [InvestedSnapshot]
  let realisedEvents: [CapitalGainEvent]
  let flows: [HoldingsFlowEntry]
  let openLots: [CostBasisLot]

  /// Primary (SQL-sourced) entry: consumes the reduced key-event legs
  /// (already ordered `(date, transaction_id, sort_order)`).
  static func build(
    legRows: [CostBasisEventLegRow],
    referenceCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> HoldingsCostLedger {
    let grouped = groupByTransaction(legRows)
    try await warmRates(grouped, referenceCurrency: referenceCurrency, using: conversionService)
    return try await runPass(
      grouped,
      referenceCurrency: referenceCurrency,
      conversionService: conversionService,
      trackedAccountIds: Set(legRows.compactMap(\.accountId)))
  }

  /// Convenience for unit-test / pure call sites: flattens `[Transaction]`
  /// to `[CostBasisEventLegRow]` (mirroring the SQL query's ordering) then
  /// runs the primary build. Production sources `legRows` from
  /// `TransactionRepository.fetchCostBasisEventLegs()`.
  static func build(
    transactions: [Transaction],
    referenceCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> HoldingsCostLedger {
    let legRows =
      transactions
      .flatMap { txn in
        txn.legs.enumerated().map { index, leg in
          CostBasisEventLegRow(
            transactionId: txn.id,
            date: txn.date,
            accountId: leg.accountId,
            instrument: leg.instrument,
            quantity: leg.quantity,
            type: leg.type,
            sortOrder: index)
        }
      }
      .sorted {
        ($0.date, $0.transactionId.uuidString, $0.sortOrder)
          < ($1.date, $1.transactionId.uuidString, $1.sortOrder)
      }
    return try await build(
      legRows: legRows,
      referenceCurrency: referenceCurrency,
      conversionService: conversionService)
  }

  // MARK: - Pass phases

  /// One transaction's grouped legs, in the query's contiguous order.
  private struct TransactionGroup {
    let id: UUID
    let date: Date
    var legs: [TransactionLeg]
  }

  /// Group legs back into per-transaction inputs, preserving the query's
  /// order so each transaction's legs stay contiguous and transactions
  /// stay in date order.
  private static func groupByTransaction(_ legRows: [CostBasisEventLegRow]) -> [TransactionGroup] {
    var order: [UUID] = []
    var byId: [UUID: TransactionGroup] = [:]
    for row in legRows {
      if byId[row.transactionId] == nil {
        order.append(row.transactionId)
        byId[row.transactionId] = TransactionGroup(id: row.transactionId, date: row.date, legs: [])
      }
      byId[row.transactionId]?.legs.append(
        TransactionLeg(
          accountId: row.accountId,
          instrument: row.instrument,
          quantity: row.quantity,
          type: row.type))
    }
    return order.compactMap { byId[$0] }
  }

  /// Warm the needed rates in ONE batch so the classifier pass hits a warm
  /// conversion cache instead of N serial provider hops. Dedupe to distinct
  /// (non-reference instrument, transaction-date) pairs — the daily rate is
  /// identical for every event that day.
  private static func warmRates(
    _ groups: [TransactionGroup],
    referenceCurrency: Instrument,
    using conversionService: any InstrumentConversionService
  ) async throws {
    struct RateKey: Hashable {
      let instrumentId: String
      let date: Date
    }
    var seen: Set<RateKey> = []
    var warm: [BatchConversionRequest] = []
    for group in groups {
      for leg in group.legs where leg.instrument != referenceCurrency {
        guard seen.insert(RateKey(instrumentId: leg.instrument.id, date: group.date)).inserted
        else { continue }
        warm.append(
          BatchConversionRequest(
            amount: InstrumentAmount(quantity: 1, instrument: leg.instrument),
            target: referenceCurrency,
            date: group.date))
      }
    }
    guard !warm.isEmpty else { return }
    _ = try await conversionService.convertResultBatch(warm)
  }

  /// Single FIFO pass over the reduced, rate-warm event stream.
  private static func runPass(
    _ groups: [TransactionGroup],
    referenceCurrency: Instrument,
    conversionService: any InstrumentConversionService,
    trackedAccountIds: Set<UUID>
  ) async throws -> HoldingsCostLedger {
    var pass = Pass()
    var snapshots: [InvestedSnapshot] = []

    for group in groups {
      try Task.checkCancellation()
      let events = try await CostBasisEventBuilder.events(
        legs: group.legs,
        on: group.date,
        trackedAccountIds: trackedAccountIds,
        referenceCurrency: referenceCurrency,
        conversionService: conversionService)
      // Disposals + moves before acquisitions so a same-txn buy is not
      // immediately consumed by a fee/gas leg in the same transaction.
      var touched: Set<TouchKey> = []
      for event in events.sorted(by: disposalsFirst) {
        pass.apply(event, on: group.date)
        touched.formUnion(touchedKeys(for: event))
      }
      for key in touched {
        guard let instrument = instrument(forId: key.instrumentId, in: group.legs) else { continue }
        let invested =
          pass.engine
          .openLots(for: instrument, account: key.account)
          .reduce(Decimal(0)) { $0 + $1.remainingCost }
        snapshots.append(
          InvestedSnapshot(
            date: group.date,
            account: key.account,
            instrument: instrument,
            remainingInvested: invested))
      }
    }
    return HoldingsCostLedger(
      investedSnapshots: snapshots,
      realisedEvents: pass.realised,
      flows: pass.flows,
      openLots: pass.engine.allOpenLots())
  }

  /// Mutable accumulator threaded through the single FIFO pass: the engine
  /// plus the realised events and market-valued flows it produces.
  private struct Pass {
    var engine = CostBasisEngine()
    var realised: [CapitalGainEvent] = []
    var flows: [HoldingsFlowEntry] = []

    /// Apply one event to the engine and record its market-valued flow(s).
    /// The touched `(account, instrument)` buckets are derived separately by
    /// `touchedKeys(for:)`.
    mutating func apply(_ event: CostBasisEvent, on date: Date) {
      switch event {
      case let .disposal(instrument, quantity, proceedsPerUnit, account):
        realised.append(
          contentsOf: engine.processSell(
            instrument: instrument,
            quantity: quantity,
            proceedsPerUnit: proceedsPerUnit,
            date: date,
            account: account))
        flows.append(
          HoldingsFlowEntry(
            date: date,
            account: account,
            instrument: instrument,
            amount: -(quantity * proceedsPerUnit),
            counterpartyAccount: nil))
      case let .move(instrument, quantity, from, to, marketValue):
        engine.moveLots(instrument: instrument, quantity: quantity, from: from, to: to)
        flows.append(
          HoldingsFlowEntry(
            date: date,
            account: from,
            instrument: instrument,
            amount: -marketValue,
            counterpartyAccount: to))
        flows.append(
          HoldingsFlowEntry(
            date: date,
            account: to,
            instrument: instrument,
            amount: marketValue,
            counterpartyAccount: from))
      case let .acquisition(instrument, quantity, costPerUnit, account):
        engine.processBuy(
          instrument: instrument,
          quantity: quantity,
          costPerUnit: costPerUnit,
          date: date,
          account: account)
        flows.append(
          HoldingsFlowEntry(
            date: date,
            account: account,
            instrument: instrument,
            amount: quantity * costPerUnit,
            counterpartyAccount: nil))
      }
    }
  }

  /// The `(account, instrument)` buckets an event touches, whose invested
  /// snapshot must be re-emitted for the transaction. A move touches both
  /// its source and destination bucket.
  private static func touchedKeys(for event: CostBasisEvent) -> [TouchKey] {
    switch event {
    case let .disposal(instrument, _, _, account):
      return [TouchKey(account: account, instrumentId: instrument.id)]
    case let .move(instrument, _, from, to, _):
      return [
        TouchKey(account: from, instrumentId: instrument.id),
        TouchKey(account: to, instrumentId: instrument.id),
      ]
    case let .acquisition(instrument, _, _, account):
      return [TouchKey(account: account, instrumentId: instrument.id)]
    }
  }

  private struct TouchKey: Hashable {
    let account: UUID?
    let instrumentId: String
  }

  /// Orders same-transaction events so disposals and moves run before
  /// acquisitions (a fee/gas disposal must draw from pre-existing lots, not
  /// the lot acquired in the same transaction).
  private static func disposalsFirst(_ lhs: CostBasisEvent, _ rhs: CostBasisEvent) -> Bool {
    func rank(_ event: CostBasisEvent) -> Int {
      switch event {
      case .disposal: return 0
      case .move: return 1
      case .acquisition: return 2
      }
    }
    return rank(lhs) < rank(rhs)
  }

  private static func instrument(forId id: String, in legs: [TransactionLeg]) -> Instrument? {
    legs.first { $0.instrument.id == id }?.instrument
  }
}

extension HoldingsCostLedger: Equatable {}

extension HoldingsCostLedger {
  /// The degraded/no-data ledger: every query returns 0 / empty. Used by
  /// consumers when a build is unavailable (Rule 11) or while the
  /// cross-chain identity migration is running, so a failed/gated ledger
  /// never partially sums.
  static var empty: HoldingsCostLedger {
    HoldingsCostLedger(investedSnapshots: [], realisedEvents: [], flows: [], openLots: [])
  }
}

extension HoldingsCostLedger {
  /// Remaining amount invested across `accountIds` at-or-before `day`,
  /// carrying forward the latest change-point per (account, instrument).
  func remainingInvested(accountIds: Set<UUID>, onOrBefore day: Date) -> Decimal {
    latestLevels(accountIds: accountIds, instrumentId: nil, onOrBefore: day)
  }

  /// Remaining amount invested across `accountIds` for one instrument
  /// at-or-before `day`.
  func remainingInvested(
    accountIds: Set<UUID>, instrument: Instrument, onOrBefore day: Date
  ) -> Decimal {
    latestLevels(accountIds: accountIds, instrumentId: instrument.id, onOrBefore: day)
  }

  private func latestLevels(
    accountIds: Set<UUID>, instrumentId: String?, onOrBefore day: Date
  ) -> Decimal {
    struct Key: Hashable {
      let account: UUID?
      let instrumentId: String
    }
    var latest: [Key: (date: Date, value: Decimal)] = [:]
    for snap in investedSnapshots {
      guard let account = snap.account, accountIds.contains(account) else { continue }
      if let want = instrumentId, snap.instrument.id != want { continue }
      guard Calendar.utc.startOfDay(for: snap.date) <= day else { continue }
      let key = Key(account: account, instrumentId: snap.instrument.id)
      if let existing = latest[key], existing.date >= snap.date { continue }
      latest[key] = (snap.date, snap.remainingInvested)
    }
    return latest.values.reduce(Decimal(0)) { $0 + $1.value }
  }

  /// Market-valued flows for the viewed account set, as `CashFlow`s: drop
  /// internal moves (both endpoints in the set net to zero), keep external
  /// buys/sells/income/spends and moves to/from accounts outside the set.
  func cashFlows(accountIds: Set<UUID>) -> [CashFlow] {
    flows
      .filter { entry in
        guard let account = entry.account, accountIds.contains(account) else { return false }
        if let counterparty = entry.counterpartyAccount, accountIds.contains(counterparty) {
          return false  // internal transfer within the viewed set
        }
        return true
      }
      .sorted { $0.date < $1.date }
      .map { CashFlow(date: $0.date, amount: $0.amount) }
  }
}

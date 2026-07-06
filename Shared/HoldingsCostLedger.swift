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
  /// `(account, instrument)` keys whose build failed a genuine (non-cancel)
  /// conversion. Per Rule 11 the ledger never partially sums these: a query
  /// whose scope includes any unavailable key returns `nil`. Populated only
  /// on a real provider failure — a `.knownZero` (unpriced / spam) values at
  /// 0 and stays available.
  private let unavailableKeys: Set<TouchKey>

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
      // Rates are day-granular; key + request on the UTC start-of-day so
      // multiple same-day transactions warm one request (matching the
      // "(instrument, day)" intent and the `latestLevels` day convention).
      let day = Calendar.utc.startOfDay(for: group.date)
      for leg in group.legs where leg.instrument != referenceCurrency {
        guard seen.insert(RateKey(instrumentId: leg.instrument.id, date: day)).inserted
        else { continue }
        warm.append(
          BatchConversionRequest(
            amount: InstrumentAmount(quantity: 1, instrument: leg.instrument),
            target: referenceCurrency,
            date: day))
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
    var unavailable: Set<TouchKey> = []

    for group in groups {
      try Task.checkCancellation()
      do {
        let events = try await CostBasisEventBuilder.events(
          legs: group.legs,
          on: group.date,
          trackedAccountIds: trackedAccountIds,
          referenceCurrency: referenceCurrency,
          conversionService: conversionService)
        // Acquisitions before disposals so a same-txn fee/gas leg with no
        // prior lot draws the just-acquired lot instead of being dropped;
        // FIFO still drains older pre-existing lots first when they exist.
        var touched: Set<TouchKey> = []
        for event in events.sorted(by: acquisitionsFirst) {
          pass.apply(event, on: group.date)
          touched.formUnion(touchedKeys(for: event))
        }
        for key in touched {
          let invested =
            pass.engine
            .openLots(for: key.instrument, account: key.account)
            .reduce(Decimal(0)) { $0 + $1.remainingCost }
          snapshots.append(
            InvestedSnapshot(
              date: group.date,
              account: key.account,
              instrument: key.instrument,
              remainingInvested: invested))
        }
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Rule 11: a genuine conversion failure degrades only the
        // `(account, instrument)` keys this transaction's non-fiat legs
        // touch. Skip its snapshots/realised/flows and keep processing the
        // rest of the profile — sibling keys stay computable.
        unavailable.formUnion(nonFiatKeys(in: group))
      }
    }
    return HoldingsCostLedger(
      investedSnapshots: snapshots,
      realisedEvents: pass.realised,
      flows: pass.flows,
      openLots: pass.engine.allOpenLots(),
      unavailableKeys: unavailable)
  }

  /// The `(account, instrument)` keys of a transaction's non-fiat legs —
  /// the buckets marked unavailable when the group's conversion fails.
  private static func nonFiatKeys(in group: TransactionGroup) -> [TouchKey] {
    group.legs
      .filter { $0.instrument.kind != .fiatCurrency }
      .map { TouchKey(account: $0.accountId, instrument: $0.instrument) }
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
      return [TouchKey(account: account, instrument: instrument)]
    case let .move(instrument, _, from, to, _):
      return [
        TouchKey(account: from, instrument: instrument),
        TouchKey(account: to, instrument: instrument),
      ]
    case let .acquisition(instrument, _, _, account):
      return [TouchKey(account: account, instrument: instrument)]
    }
  }

  /// A holding bucket: one instrument held in one account. Carries the
  /// `Instrument` value directly (it is already on every `CostBasisEvent`
  /// case and is `Hashable`), avoiding a re-lookup by id.
  private struct TouchKey: Hashable {
    let account: UUID?
    let instrument: Instrument
  }

  /// Orders same-transaction events so acquisitions run before disposals
  /// (moves in between). A fee/gas disposal then draws the just-acquired lot
  /// when no older lot exists, rather than being dropped against an empty
  /// bucket; FIFO still consumes older pre-existing lots first.
  private static func acquisitionsFirst(_ lhs: CostBasisEvent, _ rhs: CostBasisEvent) -> Bool {
    func rank(_ event: CostBasisEvent) -> Int {
      switch event {
      case .acquisition: return 0
      case .move: return 1
      case .disposal: return 2
      }
    }
    return rank(lhs) < rank(rhs)
  }
}

extension HoldingsCostLedger: Equatable {}

extension HoldingsCostLedger {
  /// The no-data ledger: every query returns 0 / empty. This is ONLY the
  /// migration-gate sentinel — returned by `HoldingsCostLedgerStore.ledger()`
  /// while the cross-chain identity migration is running, when no cost-basis
  /// data exists yet so 0/empty is honest. It is NOT a substitute for a failed
  /// build: a genuine build failure must propagate/throw and be surfaced as
  /// unavailable (Rule 11), never coalesced with `(try? await ledger()) ??
  /// .empty` — because `.empty`'s `unavailableKeys` is empty, `remainingInvested`
  /// returns 0 (not nil), which would render a real failure as "0 invested".
  static var empty: HoldingsCostLedger {
    HoldingsCostLedger(
      investedSnapshots: [], realisedEvents: [], flows: [], openLots: [], unavailableKeys: [])
  }
}

extension HoldingsCostLedger {
  /// Instrument ids whose build hit a genuine (non-cancel) conversion failure
  /// (Rule 11). Consumers that read `realisedEvents` / `openLots` / `flows`
  /// directly (`CapitalGainsCalculator`, `ProfitLossCalculator`) must consult
  /// this: a disposal or lot for such an instrument may have been dropped, so
  /// a figure that includes it would be understated and must be marked
  /// unavailable rather than rendered as complete.
  var unavailableInstrumentIds: Set<String> {
    Set(unavailableKeys.map(\.instrument.id))
  }

  /// Remaining amount invested across `accountIds` at-or-before `day`,
  /// carrying forward the latest change-point per (account, instrument).
  /// Returns `nil` (never a partial sum, Rule 11) if any in-scope
  /// `(account, instrument)` key is unavailable — i.e. any instrument held
  /// by one of `accountIds` failed conversion.
  func remainingInvested(accountIds: Set<UUID>, onOrBefore day: Date) -> Decimal? {
    guard !hasUnavailable(accountIds: accountIds, instrument: nil) else { return nil }
    return latestLevels(accountIds: accountIds, instrumentId: nil, onOrBefore: day)
  }

  /// Remaining amount invested across `accountIds` for one instrument
  /// at-or-before `day`. Returns `nil` if that `(account, instrument)` key is
  /// unavailable; sibling instruments do not affect it.
  func remainingInvested(
    accountIds: Set<UUID>, instrument: Instrument, onOrBefore day: Date
  ) -> Decimal? {
    guard !hasUnavailable(accountIds: accountIds, instrument: instrument) else { return nil }
    return latestLevels(accountIds: accountIds, instrumentId: instrument.id, onOrBefore: day)
  }

  /// Whether any unavailable key is in scope: its account is in `accountIds`
  /// and (when `instrument` is given) its instrument matches.
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
    // Snapshots arrive in processing order (date, then transaction). For a
    // given (account, instrument, day) the LAST-processed snapshot wins, so
    // a later same-day transaction overwrites an earlier one — never the
    // reverse.
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

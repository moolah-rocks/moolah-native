import Foundation
import OSLog

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
  /// Keys whose build hit a genuine conversion failure. `.knownZero` remains available.
  let unavailableKeys: Set<TouchKey>
  let unavailableInputs: Set<HoldingsCostLedgerUnavailableInput>
  let disposalCandidates: Set<HoldingsCostLedgerDisposalCandidate>
  let moveCandidates: Set<HoldingsCostLedgerMoveCandidate>
  private static let logger = Logger(subsystem: "com.moolah.app", category: "HoldingsCostLedger")

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

  /// Convenience for unit-test / pure call sites.
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

  private struct TransactionGroup {
    let id: UUID
    let date: Date
    var legs: [TransactionLeg]
  }

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
    var pass = HoldingsCostLedgerPass()
    var snapshots: [InvestedSnapshot] = []
    var unavailable: Set<TouchKey> = []
    var unavailableInputs: Set<HoldingsCostLedgerUnavailableInput> = []
    var disposalCandidates: Set<HoldingsCostLedgerDisposalCandidate> = []
    var moveCandidates: Set<HoldingsCostLedgerMoveCandidate> = []

    for group in groups {
      try Task.checkCancellation()
      disposalCandidates.formUnion(realisedGainDisposalCandidates(in: group))
      moveCandidates.formUnion(realisedGainMoveCandidates(in: group))
      do {
        let events = try await CostBasisEventBuilder.events(
          sourceTransactionId: group.id,
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
        snapshots.append(contentsOf: investedSnapshots(for: touched, on: group.date, pass: pass))
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // Rule 11: a genuine conversion failure degrades only the
        // `(account, instrument)` keys this transaction's non-fiat legs
        // touch. Skip its snapshots/realised/flows and keep processing the
        // rest of the profile — sibling keys stay computable.
        recordUnavailableInput(
          for: group, error: error, unavailable: &unavailable, inputs: &unavailableInputs)
      }
    }
    return HoldingsCostLedger(
      investedSnapshots: snapshots,
      realisedEvents: pass.realised,
      flows: pass.flows,
      openLots: pass.engine.allOpenLots(),
      unavailableKeys: unavailable,
      unavailableInputs: unavailableInputs,
      disposalCandidates: disposalCandidates,
      moveCandidates: moveCandidates)
  }

  private static func investedSnapshots(
    for keys: Set<TouchKey>,
    on date: Date,
    pass: HoldingsCostLedgerPass
  ) -> [InvestedSnapshot] {
    keys.map { key in
      let invested =
        pass.engine
        .openLots(for: key.instrument, account: key.account)
        .reduce(Decimal(0)) { $0 + $1.remainingCost }
      return InvestedSnapshot(
        date: date,
        account: key.account,
        instrument: key.instrument,
        remainingInvested: invested)
    }
  }

  /// The `(account, instrument)` keys of a transaction's non-fiat legs —
  /// the buckets marked unavailable when the group's conversion fails.
  private static func nonFiatKeys(in group: TransactionGroup) -> [TouchKey] {
    group.legs
      .filter { $0.instrument.kind != .fiatCurrency }
      .map { TouchKey(account: $0.accountId, instrument: $0.instrument) }
  }

  private static func mayEmitDisposal(in group: TransactionGroup) -> Bool {
    group.legs.contains { leg in
      leg.instrument.kind != .fiatCurrency
        && ((leg.type == .trade && leg.quantity < 0)
          || (leg.type == .expense && leg.quantity < 0))
    }
  }

  private static func realisedGainDisposalCandidates(
    in group: TransactionGroup
  ) -> Set<HoldingsCostLedgerDisposalCandidate> {
    Set(
      group.legs.compactMap { leg in
        guard leg.instrument.kind != .fiatCurrency else { return nil }
        guard
          (leg.type == .trade && leg.quantity < 0)
            || (leg.type == .expense && leg.quantity < 0)
        else { return nil }
        return HoldingsCostLedgerDisposalCandidate(
          date: group.date,
          key: TouchKey(account: leg.accountId, instrument: leg.instrument))
      })
  }

  private static func realisedGainMoveCandidates(
    in group: TransactionGroup
  ) -> Set<HoldingsCostLedgerMoveCandidate> {
    let transfers = group.legs.filter {
      $0.type == .transfer && $0.instrument.kind != .fiatCurrency
    }
    guard let source = transfers.first(where: { $0.quantity < 0 }),
      let destination = transfers.first(where: { $0.quantity > 0 }),
      source.instrument == destination.instrument
    else { return [] }
    return [
      HoldingsCostLedgerMoveCandidate(
        date: group.date,
        source: TouchKey(account: source.accountId, instrument: source.instrument),
        destination: TouchKey(account: destination.accountId, instrument: destination.instrument))
    ]
  }

  private static func recordUnavailableInput(
    for group: TransactionGroup,
    error: Error,
    unavailable: inout Set<TouchKey>,
    inputs: inout Set<HoldingsCostLedgerUnavailableInput>
  ) {
    let keys = nonFiatKeys(in: group)
    unavailable.formUnion(keys)
    logger.error(
      "Cost-basis conversion failed for transaction \(group.id, privacy: .public) on \(group.date, privacy: .public): \(error.localizedDescription, privacy: .public)"
    )
    inputs.insert(
      HoldingsCostLedgerUnavailableInput(
        date: group.date,
        keys: Set(keys),
        mayAffectRealisedGains: mayEmitDisposal(in: group)))
  }

  /// The `(account, instrument)` buckets an event touches, whose invested
  /// snapshot must be re-emitted for the transaction. A move touches both
  /// its source and destination bucket.
  private static func touchedKeys(for event: CostBasisEvent) -> [TouchKey] {
    switch event {
    case let .disposal(instrument, _, _, account, _):
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
  struct TouchKey: Hashable {
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

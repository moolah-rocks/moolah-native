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
  /// Keys whose build hit a genuine conversion failure. `.knownZero` remains available.
  let unavailableKeys: Set<TouchKey>
  let unavailableInputs: Set<HoldingsCostLedgerUnavailableInput>
  let disposalCandidates: Set<HoldingsCostLedgerDisposalCandidate>
  let moveCandidates: Set<HoldingsCostLedgerMoveCandidate>

  static func build(
    legRows: [CostBasisEventLegRow],
    referenceCurrency: Instrument,
    conversionService: any InstrumentConversionService,
    taxOwnershipResolver: TaxOwnershipResolver? = nil
  ) async throws -> HoldingsCostLedger {
    let grouped = groupByTransaction(legRows, taxOwnershipResolver: taxOwnershipResolver)
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
    conversionService: any InstrumentConversionService,
    taxOwnershipResolver: TaxOwnershipResolver? = nil
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
            sortOrder: index,
            taxOwnerIds: taxOwnershipResolver?
              .allocationsForAccount(leg.accountId)
              .map(\.ownerId) ?? [])
        }
      }
      .sorted {
        ($0.date, $0.transactionId.uuidString, $0.sortOrder)
          < ($1.date, $1.transactionId.uuidString, $1.sortOrder)
      }
    return try await build(
      legRows: legRows,
      referenceCurrency: referenceCurrency,
      conversionService: conversionService,
      taxOwnershipResolver: taxOwnershipResolver)
  }

  struct TransactionGroup {
    let id: UUID
    let date: Date
    var legs: [TransactionLeg]
    var taxOwnerIdsByAccount: [UUID?: [UUID]]
  }

  private static func groupByTransaction(
    _ legRows: [CostBasisEventLegRow],
    taxOwnershipResolver: TaxOwnershipResolver? = nil
  ) -> [TransactionGroup] {
    var order: [UUID] = []
    var byId: [UUID: TransactionGroup] = [:]
    for row in legRows {
      if byId[row.transactionId] == nil {
        order.append(row.transactionId)
        byId[row.transactionId] = TransactionGroup(
          id: row.transactionId, date: row.date, legs: [], taxOwnerIdsByAccount: [:])
      }
      let ownerIds =
        taxOwnershipResolver?
        .allocationsForAccount(row.accountId)
        .map(\.ownerId) ?? row.taxOwnerIds
      if !ownerIds.isEmpty {
        byId[row.transactionId]?.taxOwnerIdsByAccount[row.accountId] = ownerIds
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
          conversionService: conversionService,
          taxOwnerIdsByAccount: group.taxOwnerIdsByAccount)
        snapshots.append(contentsOf: applyEvents(events, to: &pass, on: group.date))
      } catch let error as CostBasisTransferEventBuilder.MarketValueFailure {
        snapshots.append(contentsOf: applyEvents(error.fallbackEvents, to: &pass, on: group.date))
        recordTransferMarketValueFailure(
          error,
          for: group,
          unavailable: &unavailable,
          inputs: &unavailableInputs)
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
}

extension HoldingsCostLedger: Equatable {}

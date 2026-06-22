import Foundation
import OSLog

private let transactionLogger = Logger(
  subsystem: "com.moolah.app", category: "Transaction.withRunningBalances")

/// A page of transactions returned from the repository, including the account
/// balance prior to the earliest transaction in this page.
///
/// `Equatable` is required so the reactive observation surface can apply
/// `removeDuplicates()` — identical re-fetches (e.g. after a write to a row
/// that doesn't affect the page) are coalesced into a single emission. All
/// stored fields are themselves `Equatable` (`[Transaction]` via
/// `Transaction: Hashable`; `Instrument` and `InstrumentAmount` via
/// `Hashable`; `Int?`), so the synthesised conformance is correct.
struct TransactionPage: Sendable, Equatable {
  let transactions: [Transaction]
  /// The instrument in which the running balance column should be displayed for
  /// this fetch. For account-scoped fetches this is the account's own instrument;
  /// for global fetches it's the profile instrument. Always populated — even when
  /// `priorBalance` is `nil` due to a conversion failure.
  let targetInstrument: Instrument
  /// Account balance before the oldest transaction in `transactions`. `nil` when
  /// the repository could not compute it (e.g. exchange-rate lookup failed). The
  /// transactions themselves are still returned so the list renders; running
  /// balances are just unavailable.
  let priorBalance: InstrumentAmount?
  let totalCount: Int?

  // MARK: - Running balances

  /// Computes the running balance after each transaction, converting each leg
  /// to the target instrument. Transactions must be ordered newest-first (as
  /// returned by the repository). `priorBalance` is the account balance
  /// before the oldest transaction in the list.
  ///
  /// All legs are converted at `Date()` — *not* `transaction.date`. The
  /// running balance has to tie out to the live account balance (which is
  /// also computed at "now"); using historic per-date rates would make
  /// the balance column drift from the account header. Treat the display
  /// amount on each row as "what this transaction is worth at today's
  /// rate," not "what it was worth when it happened." See #530.
  ///
  /// The algorithm is single-pass:
  ///   1. Walk every leg once to enumerate the unique source instruments
  ///      that need a rate.
  ///   2. Fetch one rate per instrument from `conversionService` in a single
  ///      `convertResultBatch` call — the parent only suspends once for the
  ///      whole batch, regardless of how many instruments are involved.
  ///   3. Apply rates per leg synchronously. For all-target-instrument data
  ///      (the common scheduled / native-account case) phase 1 yields an
  ///      empty set, phase 2 is a no-op, and phase 3 has zero suspension
  ///      points.
  ///
  /// Graceful degradation: if a rate fetch fails for instrument X, every
  /// transaction with an X leg is returned with `displayAmount == nil` and
  /// `balance == nil`, and the running balance is broken from that row
  /// onward. The first such failure is exposed as `firstConversionError`
  /// so callers can surface a retry path. Per Rule 11 of
  /// `guides/INSTRUMENT_CONVERSION_GUIDE.md`, each failure is logged via
  /// `os.Logger` at `warning` level — once per failed instrument, not once
  /// per affected leg.
  ///
  /// `@MainActor`-annotated so calls from a `@MainActor` caller (the
  /// `TransactionStore`) take the same-isolation fast path. For all-target
  /// data (the upcoming-card / scheduled cases) the `await` resolves
  /// without suspending and the function is effectively a synchronous
  /// call. Without this, hopping off main and back is dominated on cold
  /// launch by waiting for the main actor to drain its queue of other
  /// stores' bg-fetch domain conversions — measured ~600 ms even when the
  /// loop body itself is < 5 ms. See #530.
  @MainActor
  static func withRunningBalances(
    transactions: [Transaction],
    priorBalance: InstrumentAmount?,
    accountId: UUID?,
    earmarkId: UUID? = nil,
    targetInstrument: Instrument,
    conversionService: InstrumentConversionService
  ) async -> RunningBalanceResult {
    let prefetched = await prefetchRates(
      for: transactions,
      targetInstrument: targetInstrument,
      conversionService: conversionService)
    return accumulateRunningBalances(
      transactions: transactions,
      priorBalance: priorBalance,
      accountId: accountId,
      earmarkId: earmarkId,
      targetInstrument: targetInstrument,
      prefetched: prefetched)
  }

  // MARK: - Rate prefetch

  /// Outcome of a single per-instrument rate prefetch. Sendable so it can
  /// flow out of a `TaskGroup` child task.
  ///
  /// `knownZero` is distinct from `failure`: it means the conversion
  /// service intentionally resolved the source instrument to a zero
  /// contribution (e.g. an `.unpriced` or `.spam` crypto registration —
  /// see `ConversionResult.knownZero`). A `failure` is a transient
  /// rate-source outage that must blank the running balance per Rule 11
  /// of `guides/INSTRUMENT_CONVERSION_GUIDE.md`.
  private enum RatePrefetch: Sendable {
    case rate(Decimal)
    case knownZero
    case failure(String)
  }

  /// Fetched rates, intentional-zero instruments, and per-instrument
  /// failures, keyed by source instrument. Returned by `prefetchRates(...)`
  /// and consumed by `accumulateRunningBalances(...)`.
  private struct PrefetchedRates {
    let rates: [Instrument: Decimal]
    let knownZero: Set<Instrument>
    let failures: [Instrument: String]
  }

  @MainActor
  private static func prefetchRates(
    for transactions: [Transaction],
    targetInstrument: Instrument,
    conversionService: InstrumentConversionService
  ) async -> PrefetchedRates {
    var sources: [Instrument] = []
    var seen: Set<Instrument> = []
    for transaction in transactions {
      for leg in transaction.legs
      where leg.instrument != targetInstrument && seen.insert(leg.instrument).inserted {
        sources.append(leg.instrument)
      }
    }
    if sources.isEmpty {
      return PrefetchedRates(rates: [:], knownZero: [], failures: [:])
    }

    // One rate per UNIQUE source instrument: a 1-unit `convertResult`
    // request per instrument, resolved in a single batched hop. `sources`
    // preserves discovery order so each outcome maps back to its
    // instrument by index. `convertResult` (not `convert`) so the
    // `.knownZero` outcome (an `.unpriced` / `.spam` crypto token) stays an
    // intentional zero rather than a real rate or a failure — issue #790: a
    // spam ERC-20 with a copied ticker must contribute zero to the running
    // balance, not poison it.
    let asOf = Date()
    let requests = sources.map { instrument in
      BatchConversionRequest(
        amount: InstrumentAmount(quantity: Decimal(1), instrument: instrument),
        target: targetInstrument,
        date: asOf)
    }
    let outcomes: [BatchConversionOutcome]
    do {
      outcomes = try await conversionService.convertResultBatch(requests)
    } catch {
      // Cancellation is the only throw from `convertResultBatch`. The
      // surrounding `withRunningBalances` is non-throwing and the running
      // balance is best-effort, so degrade every source to a failure —
      // each affected row blanks per Rule 11, same as if its rate fetch
      // had failed.
      var failures: [Instrument: String] = [:]
      for instrument in sources { failures[instrument] = error.localizedDescription }
      return PrefetchedRates(rates: [:], knownZero: [], failures: failures)
    }

    var rates: [Instrument: Decimal] = [:]
    var knownZero: Set<Instrument> = []
    var failures: [Instrument: String] = [:]
    for (instrument, outcome) in zip(sources, outcomes) {
      let prefetch = ratePrefetch(
        from: outcome, instrument: instrument, targetInstrument: targetInstrument)
      switch prefetch {
      case .rate(let rate): rates[instrument] = rate
      case .knownZero: knownZero.insert(instrument)
      case .failure(let description): failures[instrument] = description
      }
    }
    return PrefetchedRates(rates: rates, knownZero: knownZero, failures: failures)
  }

  /// Fold one batch outcome into a `RatePrefetch` for `instrument`. A
  /// `.value` carries the 1-unit conversion (i.e. the rate); a `.knownZero`
  /// is an intentional zero (issue #790); a `.failure` logs once — per
  /// instrument, not per affected leg (Rule 11 of
  /// `guides/INSTRUMENT_CONVERSION_GUIDE.md`) — and blanks every row with a
  /// leg in that instrument.
  private static func ratePrefetch(
    from outcome: BatchConversionOutcome,
    instrument: Instrument,
    targetInstrument: Instrument
  ) -> RatePrefetch {
    switch outcome {
    case .value(let amount):
      return .rate(amount.quantity)
    case .knownZero:
      return .knownZero
    case .failure(let error):
      transactionLogger.warning(
        """
        Failed to fetch rate \(instrument.id, privacy: .public) → \
        \(targetInstrument.id, privacy: .public): \
        \(error.localizedDescription, privacy: .public). Every \
        transaction with a \(instrument.id, privacy: .public) leg will \
        have an unavailable running balance until the rate source recovers.
        """)
      return .failure(error.localizedDescription)
    }
  }

  // MARK: - Running-balance accumulation

  private static func accumulateRunningBalances(
    transactions: [Transaction],
    priorBalance: InstrumentAmount?,
    accountId: UUID?,
    earmarkId: UUID? = nil,
    targetInstrument: Instrument,
    prefetched: PrefetchedRates
  ) -> RunningBalanceResult {
    var balance: InstrumentAmount? = priorBalance
    var rows: [TransactionWithBalance] = []
    rows.reserveCapacity(transactions.count)
    var firstConversionError: RunningBalanceConversionError?

    for transaction in transactions.reversed() {
      let outcome = convert(
        legsOf: transaction,
        targetInstrument: targetInstrument,
        prefetched: prefetched)
      switch outcome {
      case .success(let convertedLegs):
        let displayAmount = computeDisplayAmount(
          for: transaction,
          convertedLegs: convertedLegs,
          accountId: accountId,
          earmarkId: earmarkId,
          targetInstrument: targetInstrument)
        if let displayAmount, var runningBalance = balance {
          runningBalance += displayAmount
          balance = runningBalance
        }
        rows.append(
          TransactionWithBalance(
            transaction: transaction,
            convertedLegs: convertedLegs,
            displayAmounts: Transaction.computeDisplayAmounts(
              for: transaction, accountId: accountId, earmarkId: earmarkId),
            displayAmount: displayAmount,
            balance: balance))
      case .failure(let underlyingDescription):
        if firstConversionError == nil {
          firstConversionError = RunningBalanceConversionError(
            transactionId: transaction.id,
            targetInstrumentId: targetInstrument.id,
            underlyingDescription: underlyingDescription)
        }
        balance = nil
        rows.append(
          TransactionWithBalance(
            transaction: transaction,
            convertedLegs: [],
            displayAmounts: [],
            displayAmount: nil,
            balance: nil))
      }
    }

    rows.reverse()
    return RunningBalanceResult(rows: rows, firstConversionError: firstConversionError)
  }

  private enum LegConversion {
    case success([ConvertedTransactionLeg])
    case failure(String)
  }

  /// Apply prefetched rates to each leg of `transaction`. Returns
  /// `.failure` on the first leg whose source instrument has no rate
  /// (failed prefetch) so the caller can mark the row unavailable.
  ///
  /// Legs whose source instrument resolved to `.knownZero` (an
  /// `.unpriced` / `.spam` crypto registration) fold to a zero
  /// `convertedAmount` in the target instrument — the leg keeps its
  /// native quantity for display but contributes zero to the running
  /// balance, per issue #790.
  private static func convert(
    legsOf transaction: Transaction,
    targetInstrument: Instrument,
    prefetched: PrefetchedRates
  ) -> LegConversion {
    var legs: [ConvertedTransactionLeg] = []
    legs.reserveCapacity(transaction.legs.count)
    for leg in transaction.legs {
      if leg.instrument == targetInstrument {
        legs.append(ConvertedTransactionLeg(leg: leg, convertedAmount: leg.amount))
      } else if let rate = prefetched.rates[leg.instrument] {
        let amount = InstrumentAmount(
          quantity: leg.amount.quantity * rate, instrument: targetInstrument)
        legs.append(ConvertedTransactionLeg(leg: leg, convertedAmount: amount))
      } else if prefetched.knownZero.contains(leg.instrument) {
        let amount = InstrumentAmount.zero(instrument: targetInstrument)
        legs.append(ConvertedTransactionLeg(leg: leg, convertedAmount: amount))
      } else {
        let description =
          prefetched.failures[leg.instrument]
          ?? "No rate available for \(leg.instrument.id)"
        return .failure(description)
      }
    }
    return .success(legs)
  }

  // MARK: - Display-amount computation

  /// Picks the amount to display on a row: per-account sum when viewing an
  /// account, per-earmark sum when viewing an earmark, otherwise transfers
  /// show the negative-quantity leg and non-transfers sum all legs.
  private static func computeDisplayAmount(
    for transaction: Transaction,
    convertedLegs: [ConvertedTransactionLeg],
    accountId: UUID?,
    earmarkId: UUID?,
    targetInstrument: Instrument
  ) -> InstrumentAmount? {
    let zero = InstrumentAmount.zero(instrument: targetInstrument)
    if let accountId {
      return
        convertedLegs
        .filter { $0.leg.accountId == accountId }
        .reduce(zero) { $0 + $1.convertedAmount }
    }
    if let earmarkId {
      return
        convertedLegs
        .filter { $0.leg.earmarkId == earmarkId }
        .reduce(zero) { $0 + $1.convertedAmount }
    }
    // Scheduled view (no account context): transfers show the negative
    // leg; everything else sums all legs.
    let isTransfer = transaction.legs.contains { $0.type == .transfer }
    if isTransfer {
      let negativeLeg = convertedLegs.first { $0.leg.quantity < 0 }
      return negativeLeg?.convertedAmount ?? zero
    }
    return convertedLegs.reduce(zero) { $0 + $1.convertedAmount }
  }
}

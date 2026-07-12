// Backends/GRDB/Repositories/GRDBInvestmentRepository+Observation.swift

import Foundation
import GRDB

// Reactive observation surface for `InvestmentRepository`.
//
// `observeValues(accountId:page:pageSize:)` mirrors the projection of
// `fetchValues(accountId:page:pageSize:)`. `observeDailyBalances(accountId:)`
// mirrors the projection of `fetchDailyBalances(accountId:)`. Both
// observation methods capture their parameters into the GRDB tracking
// closure — changing `accountId`, `page`, or `pageSize` requires
// cancelling the prior subscription and starting a new one.
//
// `observeErrors()` exposes the shared `ObservationErrorChannel.stream`
// declared on the repo instance (see `GRDBInvestmentRepository.swift`).
//
// Error handling lives entirely in `ValueObservation+RetryingAsyncStream.swift`:
// programmer bugs trip an `assertionFailure` and surface via the channel;
// transient I/O restarts the observation with backoff (1 s, 5 s, 30 s,
// capped at 5 retries); budget exhaustion surfaces the most recent
// error. See `guides/DATABASE_CODE_GUIDE.md` §2 convention 5.
//
// **Instrument-map snapshot.** The canonical instrument registry lives
// on a separate (profile-index) database, so its lookup table cannot be
// joined into the per-profile `ValueObservation` (the synchronous
// `tracking(regions:fetch:)` closure cannot `await`).
// `observeDailyBalances(accountId:)` resolves the map once via
// `instrumentResolver` when the stream's worker task starts, captures it
// into the tracking closure, and drops `InstrumentRow.observableRegion`
// from the tracked regions (those rows live on the separate
// profile-index DB). An
// instrument-metadata edit therefore does not live-refresh an already-
// open chart until the next refetch (re-subscribe). `observeValues` and
// `observeAllValues` don't consult the instrument map, so they keep the
// plain synchronous shape. The async-resolve-then-observe bridge is
// `resolvedInstrumentMapStream` (see
// `Backends/GRDB/Observation/InstrumentMapObservationBridge.swift`).
extension GRDBInvestmentRepository {

  /// Streams `InvestmentValuePage` snapshots whenever `investment_value`
  /// changes. Initial value is the current DB state. `removeDuplicates()`
  /// (applied inside the retry helper) coalesces re-fetches that produce
  /// the same page (e.g. a write to a row outside the page window that
  /// didn't change `hasMore`). The supplied `accountId`, `page`, and
  /// `pageSize` are captured into the tracking closure — changing any of
  /// them requires cancelling the prior subscription and starting a new
  /// one with the new values.
  func observeValues(
    accountId: UUID, page: Int, pageSize: Int
  ) -> AsyncStream<InvestmentValuePage> {
    ValueObservation
      // Explicit-region form via `InvestmentValueRow.observableRegion`
      // so the sync-bookkeeping `encoded_system_fields` writes do not
      // re-fire this observation. See issue #865.
      .tracking(
        regions: [InvestmentValueRow.observableRegion],
        fetch: { [accountId, page, pageSize] database in
          let rows =
            try InvestmentValueRow
            .filter(InvestmentValueRow.Columns.accountId == accountId)
            .order(InvestmentValueRow.Columns.date.desc)
            .limit(pageSize + 1, offset: page * pageSize)
            .fetchAll(database)
          let hasMore = rows.count > pageSize
          let values = rows.prefix(pageSize).map { $0.toDomain() }
          return InvestmentValuePage(values: Array(values), hasMore: hasMore)
        }
      )
      .toRetryingAsyncStream(
        in: database,
        errorChannel: errorChannel,
        repoMethod: "GRDBInvestmentRepository.observeValues")
  }

  /// Streams `[AccountDailyBalance]` snapshots whenever the underlying
  /// `transaction` or `transaction_leg` tables change. Mirrors the
  /// projection of `fetchDailyBalances(accountId:)`: one entry per
  /// (calendar-day, instrument) tuple, sorted by date ascending.
  /// Captures `accountId` into the tracking closure. Instrument
  /// identity is resolved once at subscription start via
  /// `instrumentResolver` and captured into the stream; an
  /// instrument-metadata change does not re-fire this observation until
  /// the subscription is cancelled and restarted.
  func observeDailyBalances(
    accountId: UUID
  ) -> AsyncStream<[AccountDailyBalance]> {
    let defaultInstrument = self.defaultInstrument
    return resolvedInstrumentMapStream(
      resolver: instrumentResolver,
      errorChannel: errorChannel,
      database: database
    ) { instruments, errorChannel, database in
      ValueObservation
        // Explicit-region form so the sync-bookkeeping
        // `encoded_system_fields` writes on the tables
        // `DailyBalanceCompute` reads (transaction, transaction_leg) do
        // not re-fire this observation. See issue #865. `InstrumentRow`
        // is not tracked here — those rows live on the separate
        // profile-index database; the map is the captured `instruments`
        // snapshot.
        .tracking(
          regions: [
            TransactionRow.observableRegion,
            TransactionLegRow.observableRegion,
          ],
          fetch: { [accountId, defaultInstrument] database in
            try DailyBalanceCompute.compute(
              database: database,
              accountId: accountId,
              instruments: instruments,
              defaultInstrument: defaultInstrument)
          }
        )
        .toRetryingAsyncStream(
          in: database,
          errorChannel: errorChannel,
          repoMethod: "GRDBInvestmentRepository.observeDailyBalances")
    }
  }

  /// Tick stream over all `investment_value` rows for compatibility
  /// consumers that need a database-wide change signal. `Void`-emitting so
  /// `removeDuplicates()` can't be applied (every emission is
  /// indistinguishable); we therefore use the explicit-region
  /// `tracking(regions:fetch:)` form so a fresh-install profile with
  /// zero `investment_value` rows still emits when the first row lands.
  /// Mirrors the rate-tick stream's region-pre-declaration idiom — see
  /// `RateCacheTickStream.swift` for the rationale.
  func observeAllValues() -> AsyncStream<Void> {
    // Region-pre-declared form via `InvestmentValueRow.observableRegion`
    // — narrower than `Table("investment_value")` because it excludes
    // the sync-bookkeeping `encoded_system_fields` column. `Void`-valued
    // streams can't use `removeDuplicates`, so the region trim is the
    // only defence against system-fields writes producing spurious
    // ticks. See issue #865.
    let observation = ValueObservation.tracking(
      regions: [InvestmentValueRow.observableRegion],
      fetch: { _ in () }
    )
    let database = self.database
    return makeRetryingAsyncStream(
      makeAttempt: { errorSink in
        observation
          .values(in: database)
          .toAsyncStream(onError: errorSink)
      },
      policy: RetryingAsyncStreamPolicy(
        errorChannel: errorChannel,
        repoMethod: "GRDBInvestmentRepository.observeAllValues",
        maxFailures: 5,
        backoffs: [.seconds(1), .seconds(5), .seconds(30)]))
  }

  /// Companion error stream — see protocol doc on `observeErrors()` and
  /// the channel's docstring for the surface-then-finish contract.
  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}

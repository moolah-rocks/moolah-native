// Backends/GRDB/Repositories/GRDBTransactionRepository+Observation.swift

import Foundation
import GRDB

// Reactive observation surface for `TransactionRepository`.
//
// `observe(filter:page:pageSize:)` mirrors `fetch(filter:page:pageSize:)`
// — the read pipeline is reused via `buildFetchSnapshot(...)` so the
// emitted snapshot is structurally identical to the imperative path.
// `priorBalance` conversion is deliberately dropped from the observed
// stream: the conversion call is async and non-deterministic from a
// `ValueObservation` perspective, and the upstream fetch already runs the
// rate fetch on the consumer's actor. The consuming `TransactionStore`
// is where the snapshot meets the conversion service; this layer's
// job is only to publish the on-disk projection.
//
// `observeAll(filter:)` mirrors `fetchAll(filter:)`. Both observation
// methods capture their parameters into the GRDB tracking closure so
// changing `filter` / `page` / `pageSize` requires cancelling the prior
// subscription and starting a new one — the same contract enforced by
// `observeBudget(earmarkId:)` on `GRDBEarmarkRepository`.
//
// `observeErrors()` exposes the shared `ObservationErrorChannel.stream`
// declared on the repo instance (see `GRDBTransactionRepository.swift`).
//
// Error handling lives entirely in `ValueObservation+RetryingAsyncStream.swift`:
// programmer bugs trip an `assertionFailure` and surface via the channel;
// transient I/O restarts the observation with backoff (1 s, 5 s, 30 s,
// capped at 5 retries); budget exhaustion surfaces the most recent
// error. See `guides/DATABASE_CODE_GUIDE.md` §2 convention 5.
//
// **Cost note for measurement.** Both observation closures re-run the
// full fetch / leg join / candidate filtering on every commit to any of
// the tracked tables (`transaction`, `transaction_leg`, `account` for
// the resolved-target lookup). A profile with many transactions will
// pay the candidate-filter cost on every write. The design's
// measure-first policy applies — measure under load before
// pre-optimising here.
//
// **Instrument-map snapshot.** The canonical instrument registry lives
// on a separate (profile-index) database, so its lookup table cannot be
// joined into the per-profile `ValueObservation` (the synchronous
// `tracking(regions:fetch:)` closure cannot `await`). Each observation
// instead resolves the map once via `instrumentResolver` when the
// stream's worker task starts, captures it into the tracking closure,
// and drops `InstrumentRow.observableRegion` from the tracked regions
// (those rows live on the separate profile-index DB). An
// instrument-metadata edit therefore does not live-refresh an
// already-open list until the next refetch (re-subscribe);
// cross-database instrument-metadata live-refresh is wired via the
// shared registry's change stream.
extension GRDBTransactionRepository {

  /// Streams `TransactionPage` snapshots whenever `transaction`,
  /// `transaction_leg`, or `account` changes. Initial value is the
  /// current DB state. Instrument identity is resolved once at
  /// subscription start via `instrumentResolver` and captured into the
  /// stream; an instrument-metadata change does not re-fire this
  /// observation until the subscription is cancelled and restarted.
  /// `removeDuplicates()` (applied inside the retry helper) coalesces
  /// re-fetches that produce the same page (e.g. a write to a row
  /// outside `[page * pageSize ..< end]` that didn't change
  /// `totalCount`). The supplied `filter`, `page`, and `pageSize` are
  /// captured into the tracking closure — changing any of them requires
  /// cancelling the prior subscription and starting a new one with the
  /// new values.
  ///
  /// `priorBalance` is set to `nil` in the emitted page: the
  /// conversion-service hop is async and runs on the consumer's actor,
  /// so the observation stream itself only carries the on-disk part of
  /// the snapshot. `TransactionStore` performs the conversion after
  /// each emission, the same way the imperative path does after
  /// `fetch(...)`. `targetInstrument`, `transactions`, and `totalCount`
  /// come from `buildFetchSnapshot(...)` so the emitted projection
  /// matches `fetch(...)` exactly outside that field.
  func observe(
    filter: TransactionFilter, page: Int, pageSize: Int
  ) -> AsyncStream<TransactionPage> {
    let defaultInstrument = self.defaultInstrument
    return resolvedInstrumentMapStream(
      resolver: instrumentResolver,
      errorChannel: errorChannel,
      database: database
    ) { instruments, errorChannel, database in
      ValueObservation
        // Explicit-region form: every joined table's `observableRegion`
        // excludes the sync-bookkeeping `encoded_system_fields` blob, so
        // CKSyncEngine's per-batch system-fields write does not re-fire
        // this observation. See issue #865. `InstrumentRow` is not
        // tracked here — those rows live on the separate profile-index
        // database; the map is the captured `instruments` snapshot.
        .tracking(
          regions: [
            TransactionRow.observableRegion,
            TransactionLegRow.observableRegion,
            AccountRow.observableRegion,
          ],
          fetch: { [filter, page, pageSize] database in
            let snapshot = try Self.buildFetchSnapshot(
              database: database,
              input: FetchSnapshotInput(
                filter: filter,
                page: page,
                pageSize: pageSize,
                defaultInstrument: defaultInstrument,
                instruments: instruments))
            return TransactionPage(
              transactions: snapshot.pageTransactions,
              targetInstrument: snapshot.resolvedTarget,
              priorBalance: nil,
              totalCount: snapshot.totalCount)
          }
        )
        .toRetryingAsyncStream(
          in: database,
          errorChannel: errorChannel,
          repoMethod: "GRDBTransactionRepository.observe")
    }
  }

  /// Streams `[Transaction]` snapshots whenever `transaction` or
  /// `transaction_leg` changes. Mirrors the projection of
  /// `fetchAll(filter:)`: every matching transaction with its full leg
  /// payload, ordered the same way (`date DESC, id ASC`). Instrument
  /// identity is resolved once at subscription start via
  /// `instrumentResolver` and captured into the stream; an
  /// instrument-metadata change does not re-fire this observation until
  /// the subscription is cancelled and restarted. Captures `filter`
  /// into the tracking closure — changing it requires cancelling the
  /// prior subscription.
  func observeAll(filter: TransactionFilter) -> AsyncStream<[Transaction]> {
    resolvedInstrumentMapStream(
      resolver: instrumentResolver,
      errorChannel: errorChannel,
      database: database
    ) { instruments, errorChannel, database in
      ValueObservation
        // Explicit-region form: every joined table's `observableRegion`
        // excludes the sync-bookkeeping `encoded_system_fields` blob, so
        // CKSyncEngine's per-batch system-fields write does not re-fire
        // this observation. See issue #865. `InstrumentRow` is not
        // tracked here — those rows live on the separate profile-index
        // database; the map is the captured `instruments` snapshot.
        .tracking(
          regions: [
            TransactionRow.observableRegion,
            TransactionLegRow.observableRegion,
          ],
          fetch: { [filter] database in
            let filteredRows =
              try Self.orderedFilteredRequest(filter: filter)
              .fetchAll(database)
            let legsByTxnId = try Self.fetchLegs(
              database: database,
              transactionIds: filteredRows.map(\.id),
              instruments: instruments)
            return try filteredRows.map { row in
              try row.toDomain(legs: legsByTxnId[row.id] ?? [])
            }
          }
        )
        .toRetryingAsyncStream(
          in: database,
          errorChannel: errorChannel,
          repoMethod: "GRDBTransactionRepository.observeAll")
    }
  }

  /// Companion error stream — see protocol doc on `observeErrors()` and
  /// the channel's docstring for the surface-then-finish contract.
  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}

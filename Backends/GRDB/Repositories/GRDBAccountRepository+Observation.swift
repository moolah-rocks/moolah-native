// Backends/GRDB/Repositories/GRDBAccountRepository+Observation.swift

import Foundation
import GRDB

// Reactive observation surface for `AccountRepository`.
//
// `observeAll()` returns the same domain projection as `fetchAll()`:
// account rows ordered by `position`, each populated with its full
// `Instrument` value and per-instrument `Position` totals computed from
// non-scheduled `transaction_leg` rows.
//
// `observeErrors()` exposes the shared `ObservationErrorChannel.stream`
// declared on the repo instance (see `GRDBAccountRepository.swift`).
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
// `tracking(regions:fetch:)` closure cannot `await`). The observation
// resolves the map once via `instrumentResolver` when the stream's
// worker task starts, captures it into the tracking closure, and drops
// `InstrumentRow.observableRegion` from the tracked regions (those rows
// live on the separate profile-index DB). An instrument-metadata edit
// therefore does not live-refresh an already-open list until the next refetch
// (re-subscribe); cross-database instrument-metadata live-refresh is
// wired via the shared registry's change stream in a follow-up. The
// async-resolve-then-observe bridge is `resolvedInstrumentMapStream`
// (see `Backends/GRDB/Observation/InstrumentMapObservationBridge.swift`).
extension GRDBAccountRepository {

  /// Streams `[Account]` snapshots whenever `account`,
  /// `transaction_leg`, or the joined `transaction` table changes.
  /// Initial value is the current DB state. Instrument identity is
  /// resolved once at subscription start via `instrumentResolver` and
  /// captured into the stream; an instrument-metadata change does not
  /// re-fire this observation until the subscription is cancelled and
  /// restarted. `removeDuplicates()` (applied inside the retry helper)
  /// coalesces re-fetches that produce the same domain value (e.g. a
  /// no-op write on an unrelated row).
  func observeAll() -> AsyncStream<[Account]> {
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
        //
        // Projection parity with `fetchAll()`: instruments + ordered
        // rows + computed positions, mapped to `Account` via
        // `row.toDomain`. The retry helper re-runs this closure on each
        // restart attempt, so the projection always reads the freshest
        // DB state.
        .tracking(
          regions: [
            AccountRow.observableRegion,
            AccountTaxOwnerRow.observableRegion,
            TransactionRow.observableRegion,
            TransactionLegRow.observableRegion,
          ],
          fetch: { database in
            let rows =
              try AccountRow
              .order(AccountRow.Columns.position.asc)
              .fetchAll(database)
            let positionsByAccount = try Self.computePositions(
              database: database, instruments: instruments)
            let taxOwnerIdsByAccount =
              try GRDBTaxOwnershipPersistence.accountOwnerIdsByAccount(in: database)
            return try rows.map { row in
              try row.toDomain(
                instruments: instruments,
                positions: positionsByAccount[row.id] ?? [],
                taxOwnerIds: taxOwnerIdsByAccount[row.id] ?? [])
            }
          }
        )
        .toRetryingAsyncStream(
          in: database,
          errorChannel: errorChannel,
          repoMethod: "GRDBAccountRepository.observeAll")
    }
  }

  /// Companion error stream — see protocol doc on `observeErrors()` and
  /// the channel's docstring for the surface-then-finish contract.
  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}

import Foundation
import GRDB

// Reactive observation surface for `AccountGroupRepository`.
//
// `observeAll()` returns the same domain projection as `fetchAll()`:
// every `account_group` row, ordered by `position`, mapped through
// `toDomain()`. Groups carry no per-row joined state (no positions, no
// transaction-leg derivation), so the tracking closure is a single
// `AccountGroupRow.fetchAll`.
//
// `observeErrors()` exposes the shared `ObservationErrorChannel.stream`
// declared on the repo instance (see `GRDBAccountGroupRepository.swift`).
//
// Error handling lives entirely in `ValueObservation+RetryingAsyncStream.swift`:
// programmer bugs trip an `assertionFailure` and surface via the channel;
// transient I/O restarts the observation with backoff (1 s, 5 s, 30 s,
// capped at 5 retries); budget exhaustion surfaces the most recent
// error. See `guides/DATABASE_CODE_GUIDE.md` §2 convention 5.
extension GRDBAccountGroupRepository {

  /// Streams `[AccountGroup]` snapshots whenever the `account_group`
  /// table changes. Initial value is the current DB state.
  /// `removeDuplicates()` (applied inside the retry helper) coalesces
  /// re-fetches that produce the same domain value (e.g. a no-op write
  /// on an unrelated row, or a system-fields-only write that the
  /// observable region already excludes).
  func observeAll() -> AsyncStream<[AccountGroup]> {
    ValueObservation
      // Explicit-region form via `AccountGroupRow.observableRegion` so
      // the sync-bookkeeping `encoded_system_fields` writes that land
      // after every successful CKSyncEngine send do not re-fire this
      // observation. See issue #865 and
      // `Records/AccountRow+ObservableRegion.swift`.
      .tracking(
        regions: [AccountGroupRow.observableRegion],
        fetch: { database in
          try AccountGroupRow
            .order(AccountGroupRow.Columns.position.asc)
            .fetchAll(database)
            .map { $0.toDomain() }
        }
      )
      .toRetryingAsyncStream(
        in: database,
        errorChannel: errorChannel,
        repoMethod: "GRDBAccountGroupRepository.observeAll")
  }

  /// Companion error stream — see protocol doc on `observeErrors()` and
  /// the channel's docstring for the surface-then-finish contract.
  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}

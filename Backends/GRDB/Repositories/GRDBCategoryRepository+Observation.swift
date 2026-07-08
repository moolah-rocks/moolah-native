// Backends/GRDB/Repositories/GRDBCategoryRepository+Observation.swift

import Foundation
import GRDB

// Reactive observation surface for `CategoryRepository`.
//
// `observeAll()` returns the same domain projection as `fetchAll()`:
// every `category` row, ordered by `name`, mapped through `toDomain()`.
// Categories carry no per-row joined state (no instrument, no positions,
// no transaction-leg derivation), so the tracking closure is a single
// `CategoryRow.fetchAll`.
//
// `observeErrors()` exposes the shared `ObservationErrorChannel.stream`
// declared on the repo instance (see `GRDBCategoryRepository.swift`).
//
// Error handling lives entirely in `ValueObservation+RetryingAsyncStream.swift`:
// programmer bugs trip an `assertionFailure` and surface via the channel;
// transient I/O restarts the observation with backoff (1 s, 5 s, 30 s,
// capped at 5 retries); budget exhaustion surfaces the most recent
// error. See `guides/DATABASE_CODE_GUIDE.md` §2 convention 5.
extension GRDBCategoryRepository {

  /// Streams `[Category]` snapshots whenever the `category` table
  /// changes. Initial value is the current DB state. `removeDuplicates()`
  /// (applied inside the retry helper) coalesces re-fetches that produce
  /// the same domain value (e.g. a no-op write on an unrelated row).
  func observeAll() -> AsyncStream<[Moolah.Category]> {
    ValueObservation
      // Explicit-region form via `CategoryRow.observableRegion` so the
      // sync-bookkeeping `encoded_system_fields` writes that land after
      // every successful CKSyncEngine send do not re-fire this
      // observation. See issue #865 and
      // `Records/AccountRow+ObservableRegion.swift`. The region is
      // pre-declared, so it is also empty-table-safe on a fresh-install
      // profile — no need for the row-decoder workaround the inferred
      // form depended on.
      .tracking(
        regions: [CategoryRow.observableRegion, CategoryTaxOwnerRow.observableRegion],
        fetch: { database in
          let taxOwnerIdsByCategory =
            try GRDBTaxOwnershipPersistence.categoryOwnerIdsByCategory(in: database)
          return
            try CategoryRow
            .order(CategoryRow.Columns.name.asc)
            .fetchAll(database)
            .map { $0.toDomain(taxOwnerIds: taxOwnerIdsByCategory[$0.id] ?? []) }
        }
      )
      .toRetryingAsyncStream(
        in: database,
        errorChannel: errorChannel,
        repoMethod: "GRDBCategoryRepository.observeAll")
  }

  /// Companion error stream — see protocol doc on `observeErrors()` and
  /// the channel's docstring for the surface-then-finish contract.
  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}

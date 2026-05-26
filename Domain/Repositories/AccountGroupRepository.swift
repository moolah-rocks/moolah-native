import Foundation

/// Repository for `AccountGroup` persistence and observation. Follows
/// the same async-fetching, observable contract as `EarmarkRepository`.
protocol AccountGroupRepository: Sendable {
  /// Fetches all groups, ordered by `position` ascending.
  func fetchAll() async throws -> [AccountGroup]

  /// Hot stream of group lists. Emits an initial snapshot and again on
  /// every persisted change to the `account_group` table. Errors are
  /// surfaced out-of-band on `observeErrors()` — the value stream itself
  /// is non-throwing.
  func observeAll() -> AsyncStream<[AccountGroup]>

  /// Companion error stream. A healthy observation stays quiet here for
  /// its lifetime; a programmer-bug or non-recoverable I/O error from
  /// the underlying observation is yielded once and the stream
  /// completes.
  func observeErrors() -> AsyncStream<any Error>

  /// Inserts a new group. Returns the persisted instance.
  @discardableResult
  func create(_ group: AccountGroup) async throws -> AccountGroup

  /// Updates an existing group (matched by `id`). Returns the persisted
  /// instance. Throws `BackendError.serverError(404)` when no row matches.
  @discardableResult
  func update(_ group: AccountGroup) async throws -> AccountGroup

  /// Deletes a group by id. Does not affect member accounts — callers
  /// clear `Account.groupId` on members separately if they want the
  /// back-reference removed from the child rows. The lookup layer treats
  /// orphaned ids as nil regardless, so leaving them is also safe.
  func delete(id: UUID) async throws
}

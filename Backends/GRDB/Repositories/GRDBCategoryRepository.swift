// Backends/GRDB/Repositories/GRDBCategoryRepository.swift

import Foundation
import GRDB

/// GRDB-backed implementation of `CategoryRepository`. Replaces the
/// SwiftData-backed `CloudKitCategoryRepository` for the `category`
/// table.
///
/// `delete(id:withReplacement:)` is the load-bearing case: deleting a
/// category fans out to orphaning child categories, reassigning
/// transaction legs, and either reassigning or deleting budget items
/// that referenced it. All of that lives inside a single
/// `database.write { … }` so the multi-table mutation is one
/// transaction; on any throw the entire operation rolls back.
///
/// **`@unchecked Sendable` justification.** All stored properties are
/// `let`. `database` (`any DatabaseWriter`) is itself `Sendable` (GRDB
/// protocol guarantee — the queue's serial executor mediates concurrent
/// access). `onRecordChanged` and `onRecordDeleted` are `@Sendable`
/// closures captured at init. Nothing mutates post-init, so the
/// reference can be shared across actor boundaries without a data
/// race; `@unchecked` only waives Swift's structural check that
/// `final class` types meet `Sendable`'s requirements automatically.
/// See `guides/CONCURRENCY_GUIDE.md` §2 "False Positives to Avoid",
/// Carve-out 3 (GRDB repositories).
final class GRDBCategoryRepository: CategoryRepository, @unchecked Sendable {
  // `database` and `errorChannel` are deliberately not `private` so the
  // sibling `+Observation.swift` extension can reach them. Treat them
  // as private-by-convention from elsewhere in the module.
  let database: any DatabaseWriter
  /// Receives `(recordType, id)` so deleting a category — which fans out
  /// to orphaned children, reassigned legs, and budget-item
  /// upserts/deletes — tags each downstream emit with its own type.
  private let onRecordChanged: @Sendable (String, UUID) -> Void
  private let onRecordDeleted: @Sendable (String, UUID) -> Void
  /// Single shared error channel for every `observeAll()` subscription
  /// returned by this repo instance. The bridge in
  /// `Backends/GRDB/Observation/AsyncValueObservation+AsyncStream.swift`
  /// is single-shot, so once `surfaceAndFinish(_:)` is called the
  /// channel terminates — subsequent observations from the same repo
  /// share that fate. Matches `GRDBAccountRepository.errorChannel`.
  let errorChannel = ObservationErrorChannel()

  init(
    database: any DatabaseWriter,
    onRecordChanged: @escaping @Sendable (String, UUID) -> Void = { _, _ in },
    onRecordDeleted: @escaping @Sendable (String, UUID) -> Void = { _, _ in }
  ) {
    self.database = database
    self.onRecordChanged = onRecordChanged
    self.onRecordDeleted = onRecordDeleted
  }

  // MARK: - CategoryRepository conformance

  func fetchAll() async throws -> [Moolah.Category] {
    try await database.read { database in
      try CategoryRow
        .order(CategoryRow.Columns.name.asc)
        .fetchAll(database)
        .map { $0.toDomain() }
    }
  }

  func create(_ category: Moolah.Category) async throws -> Moolah.Category {
    let row = CategoryRow(domain: category)
    try await database.write { database in
      try row.insert(database)
      try markNeedsPushSync(id: category.id, in: database)
    }
    onRecordChanged(CategoryRow.recordType, category.id)
    return row.toDomain()
  }

  func update(_ category: Moolah.Category) async throws -> Moolah.Category {
    let updated = try await database.write { database -> CategoryRow in
      guard
        var existing =
          try CategoryRow
          .filter(CategoryRow.Columns.id == category.id)
          .fetchOne(database)
      else {
        throw BackendError.serverError(404)
      }
      existing.name = category.name
      existing.parentId = category.parentId
      try existing.update(database)
      try markNeedsPushSync(id: category.id, in: database)
      return existing
    }
    onRecordChanged(CategoryRow.recordType, category.id)
    return updated.toDomain()
  }

  func delete(id: UUID, withReplacement replacementId: UUID?) async throws {
    let outcome = try await database.write { database -> DeleteOutcome in
      guard
        let existing =
          try CategoryRow
          .filter(CategoryRow.Columns.id == id)
          .fetchOne(database)
      else {
        throw BackendError.serverError(404)
      }

      let orphanedChildIds = try Self.orphanChildren(of: id, in: database)
      let reassignedLegIds = try Self.reassignLegs(
        from: id, to: replacementId, in: database)
      let budgetOutcome = try Self.reassignBudgets(
        from: id, to: replacementId, in: database)

      try existing.delete(database)
      try Self.markDeleteSideEffectsNeedsPush(
        orphanedChildIds: orphanedChildIds,
        reassignedLegIds: reassignedLegIds,
        updatedBudgetIds: budgetOutcome.updated,
        in: database)

      return DeleteOutcome(
        orphanedChildIds: orphanedChildIds,
        reassignedLegIds: reassignedLegIds,
        deletedBudgetIds: budgetOutcome.deleted,
        updatedBudgetIds: budgetOutcome.updated)
    }

    // Mirror `CloudKitCategoryRepository.performDelete`'s emit sequence:
    // delete the category itself, then fan out to children, legs, and
    // budgets. Each emit names its own recordType so the sync wiring
    // queues the right `<recordType>|<UUID>` token.
    onRecordDeleted(CategoryRow.recordType, id)
    for childId in outcome.orphanedChildIds {
      onRecordChanged(CategoryRow.recordType, childId)
    }
    for legId in outcome.reassignedLegIds {
      onRecordChanged(TransactionLegRow.recordType, legId)
    }
    for budgetId in outcome.deletedBudgetIds {
      onRecordDeleted(EarmarkBudgetItemRow.recordType, budgetId)
    }
    for budgetId in outcome.updatedBudgetIds {
      onRecordChanged(EarmarkBudgetItemRow.recordType, budgetId)
    }
  }

  // MARK: - Multi-table delete helpers
  //
  // All three helpers run inside the caller's `database.write { … }`, so
  // they receive a `Database` connection rather than a `DatabaseWriter`.
  // The helpers do not throw on missing rows — empty result sets are
  // legitimate (a leaf category has no children, an unused category has
  // no legs).

  /// Sets `parent_id = NULL` on every row whose parent is `targetId`.
  /// Returns the affected child ids so the caller can fire change hooks
  /// after the transaction commits.
  private static func orphanChildren(of targetId: UUID, in database: Database) throws -> [UUID] {
    let children =
      try CategoryRow
      .filter(CategoryRow.Columns.parentId == targetId)
      .fetchAll(database)
    let childIds = children.map(\.id)
    if !childIds.isEmpty {
      _ =
        try CategoryRow
        .filter(CategoryRow.Columns.parentId == targetId)
        .updateAll(database, [CategoryRow.Columns.parentId.set(to: nil)])
    }
    return childIds
  }

  /// Updates `category_id` on every transaction leg that referenced
  /// `deletedId` to point at `replacementId` (which may be `NULL`).
  /// Returns the affected leg ids.
  private static func reassignLegs(
    from deletedId: UUID,
    to replacementId: UUID?,
    in database: Database
  ) throws -> [UUID] {
    let legs =
      try TransactionLegRow
      .filter(TransactionLegRow.Columns.categoryId == deletedId)
      .fetchAll(database)
    let legIds = legs.map(\.id)
    if !legIds.isEmpty {
      _ =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.categoryId == deletedId)
        .updateAll(
          database,
          [TransactionLegRow.Columns.categoryId.set(to: replacementId)])
    }
    return legIds
  }

  /// For every budget item that referenced `deletedId`:
  ///   - if `replacementId` is `nil`, delete the row;
  ///   - otherwise, if the same earmark already has a budget item for
  ///     `replacementId`, delete this row (avoiding a duplicate budget
  ///     line for the same earmark/category pair);
  ///   - otherwise, rewrite this row's `category_id` to `replacementId`.
  /// Returns the ids that were deleted and the ids that were updated.
  private static func reassignBudgets(
    from deletedId: UUID,
    to replacementId: UUID?,
    in database: Database
  ) throws -> (deleted: [UUID], updated: [UUID]) {
    let affected =
      try EarmarkBudgetItemRow
      .filter(EarmarkBudgetItemRow.Columns.categoryId == deletedId)
      .fetchAll(database)
    var deleted: [UUID] = []
    var updated: [UUID] = []
    for var budget in affected {
      guard let replacementId else {
        try budget.delete(database)
        deleted.append(budget.id)
        continue
      }
      let earmarkId = budget.earmarkId
      let duplicate =
        try EarmarkBudgetItemRow
        .filter(
          EarmarkBudgetItemRow.Columns.earmarkId == earmarkId
            && EarmarkBudgetItemRow.Columns.categoryId == replacementId
        )
        .fetchOne(database)
      if duplicate != nil {
        try budget.delete(database)
        deleted.append(budget.id)
      } else {
        budget.categoryId = replacementId
        try budget.update(database)
        updated.append(budget.id)
      }
    }
    return (deleted, updated)
  }

  /// Captures the per-row id sets that the delete transaction touched so
  /// the calling closure can fan out hook fires after the transaction
  /// commits — emitting hooks inside the write would publish changes
  /// that haven't yet been made durable.
  private struct DeleteOutcome {
    let orphanedChildIds: [UUID]
    let reassignedLegIds: [UUID]
    let deletedBudgetIds: [UUID]
    let updatedBudgetIds: [UUID]
  }

  // MARK: - Sync entry points (synchronous, GRDB-queue-blocking)
  //
  // Called from the CKSyncEngine delegate executor on a non-MainActor
  // context. `DatabaseWriter.write { db in … }` has both async and sync
  // overloads; the sync form blocks the calling thread until the queue's
  // serial executor admits the closure. Never call these from
  // `@MainActor`.

  func applyRemoteChangesSync(saved rows: [CategoryRow], deleted ids: [UUID]) throws {
    try database.write { database in
      try applyRemoteChangesSync(saved: rows, deleted: ids, in: database)
    }
  }

  /// In-transaction variant — see `GRDBCSVImportProfileRepository.applyRemoteChangesSync(...:in:)`
  /// for the rationale (one commit per `applyRemoteChanges` batch, issue #872).
  func applyRemoteChangesSync(
    saved rows: [CategoryRow], deleted ids: [UUID], in database: Database
  ) throws {
    for row in rows {
      try row.upsert(database)
    }
    for id in ids {
      // Replaces v3 FKs (transaction_leg.category_id ON DELETE SET NULL,
      // earmark_budget_item.category_id ON DELETE NO ACTION). Sync deletes
      // are server-authoritative, so we cannot fail on surviving children
      // the way NO ACTION did; we delete the budget items (matching the
      // domain delete-without-replacement path in `reassignBudgets`).
      _ =
        try TransactionLegRow
        .filter(TransactionLegRow.Columns.categoryId == id)
        .updateAll(
          database,
          [TransactionLegRow.Columns.categoryId.set(to: nil)])
      _ =
        try EarmarkBudgetItemRow
        .filter(EarmarkBudgetItemRow.Columns.categoryId == id)
        .deleteAll(database)
      // category.parent_id was ON DELETE NO ACTION — children are
      // orphaned (set to NULL) in CategoryRepository.delete via
      // `orphanChildren`. Sync apply mirrors that for consistency.
      _ =
        try CategoryRow
        .filter(CategoryRow.Columns.parentId == id)
        .updateAll(
          database,
          [CategoryRow.Columns.parentId.set(to: nil)])
      _ = try CategoryRow.deleteOne(database, id: id)
    }
  }

  /// Writes (or clears) the cached system-fields blob on a single row.
  /// Returns `true` when a row was found and updated.
  @discardableResult
  func setEncodedSystemFieldsSync(id: UUID, data: Data?) throws -> Bool {
    try database.write { database in
      try CategoryRow
        .filter(CategoryRow.Columns.id == id)
        .updateAll(database, [CategoryRow.Columns.encodedSystemFields.set(to: data)])
        > 0
    }
  }

  /// Clears `encoded_system_fields` on every row. Used after an
  /// `encryptedDataReset`.
  func clearAllSystemFieldsSync() throws {
    try database.write { database in
      _ =
        try CategoryRow
        .updateAll(
          database,
          [CategoryRow.Columns.encodedSystemFields.set(to: nil)])
    }
  }

  /// Returns IDs of rows whose `encoded_system_fields` is `NULL`.
  func unsyncedRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try CategoryRow
        .filter(CategoryRow.Columns.encodedSystemFields == nil)
        .select(CategoryRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Returns IDs of every row in the table.
  func allRowIdsSync() throws -> [UUID] {
    try database.read { database in
      try CategoryRow
        .select(CategoryRow.Columns.id, as: UUID.self)
        .fetchAll(database)
    }
  }

  /// Looks up a single row by id. Used by the per-record upload path in
  /// the sync handler.
  func fetchRowSync(id: UUID) throws -> CategoryRow? {
    try database.read { database in
      try CategoryRow
        .filter(CategoryRow.Columns.id == id)
        .fetchOne(database)
    }
  }

  /// Batch lookup by ids — used by the batch-build phase of the sync
  /// handler.
  func fetchRowsSync(ids: [UUID]) throws -> [CategoryRow] {
    let idSet = Set(ids)
    return try database.read { database in
      try CategoryRow
        .filter(idSet.contains(CategoryRow.Columns.id))
        .fetchAll(database)
    }
  }

  /// Deletes every row in the table. Used by `deleteLocalData` after a
  /// remote zone deletion.
  func deleteAllSync() throws {
    try database.write { database in
      _ = try CategoryRow.deleteAll(database)
    }
  }
}

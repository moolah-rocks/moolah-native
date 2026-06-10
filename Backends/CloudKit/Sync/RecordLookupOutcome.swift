@preconcurrency import CloudKit
import Foundation

/// Tri-state outcome of looking up a single record for upload (issue #1087).
/// The send path must distinguish a row that is genuinely gone (safe to drop
/// the stale `.saveRecord` and queue a server deletion) from a lookup that
/// could not complete (a transient GRDB error, or a record type this build
/// does not handle — keep the change pending and retry, never delete a
/// possibly-live record).
///
/// `Sendable` so an outcome can flow from a `nonisolated` lookup back to the
/// `@MainActor` send path; `CKRecord` is `Sendable`-bridged under the file's
/// `@preconcurrency import CloudKit`.
enum RecordLookupOutcome: Sendable {
  /// The row exists; upload this record.
  case found(CKRecord)
  /// The query succeeded and the row is genuinely absent — drop the stale
  /// save and queue the compensating server deletion.
  case absent
  /// The lookup could not be completed (GRDB threw, or the record type is
  /// not handled by this build) — keep the change pending; never delete.
  case failed
}

/// Outcome of a per-recordType batch lookup (issue #1087). `succeeded`
/// carries the hits keyed by UUID; any requested id absent from the map is
/// genuinely gone. `failed` means the batch query threw (or the type is
/// unhandled) — every id in the group stays pending, none removed.
enum BatchLookupOutcome: Sendable {
  case succeeded([UUID: CKRecord])
  case failed
}

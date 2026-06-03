import Foundation

extension InsightDismissalRow {
  /// The CloudKit recordType on the wire. Frozen contract.
  static let recordType = "InsightDismissalRecord"

  /// Deterministic primary key for a kind: identical on every device, so the
  /// per-kind tally resolves to one record cluster-wide. Namespaced with the
  /// record type so it can never collide with another deterministic-UUID
  /// keyspace.
  static func id(for kind: InsightKind) -> UUID {
    UUID.deterministic(from: "\(recordType)|\(kind.rawValue)")
  }

  /// Canonical CloudKit `recordName` for a UUID-keyed row.
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  /// Convenience init from a kind + count. Derives the deterministic id and
  /// record name; `encodedSystemFields` starts nil (stamped post-upsert).
  init(kind: InsightKind, count: Int) {
    let id = Self.id(for: kind)
    self.id = id
    self.recordName = Self.recordName(for: id)
    self.kind = kind.rawValue
    self.count = count
    self.encodedSystemFields = nil
  }

  /// Builds a row from a domain `InsightDismissal`.
  init(domain: InsightDismissal) {
    self.init(kind: domain.kind, count: domain.count)
  }

  /// Domain projection. An unknown `kind` raw value (e.g. a kind added by a
  /// newer build that synced down to this one) yields `nil`; the caller drops
  /// it — a fatigue tally for a kind this build cannot detect is inert.
  func toDomain() -> InsightDismissal? {
    guard let resolved = InsightKind(rawValue: kind) else { return nil }
    return InsightDismissal(kind: resolved, count: count)
  }
}

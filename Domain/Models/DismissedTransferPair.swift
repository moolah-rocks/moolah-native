import Foundation

/// A user assertion that two specific transactions are NOT a transfer.
/// Detection skips any candidate pair covered by one of these.
/// Synced; respected on every device. `id` is content-addressed from
/// the unordered id pair so a re-dismissal on any device upserts the
/// same row (idempotent convergence).
struct DismissedTransferPair: Codable, Sendable, Identifiable, Hashable {
  let id: UUID
  let transactionIds: Set<UUID>
  let dismissedAt: Date

  init(transactionIds: Set<UUID>, dismissedAt: Date) {
    self.transactionIds = transactionIds
    self.dismissedAt = dismissedAt
    self.id = Self.contentAddressedID(for: transactionIds)
  }

  func covers(_ first: UUID, and second: UUID) -> Bool {
    transactionIds == [first, second]
  }

  /// The content-addressed id this pair would carry, derived from the
  /// unordered transaction-id set. Exposed so callers can build an O(1)
  /// membership set keyed by id rather than scanning pairs linearly.
  static func contentAddressedID(for transactionIds: Set<UUID>) -> UUID {
    let ordered = transactionIds.map(\.uuidString).sorted().joined(separator: ":")
    return UUID.deterministic(from: "dismissed-transfer-pair:\(ordered)")
  }
}

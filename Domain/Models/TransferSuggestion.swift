import Foundation

/// A detected fuzzy-transfer candidate: two specific transactions that
/// look like the two sides of one cross-account transfer. Synced; a
/// device that detects a pair uploads this record, peers converge on it.
/// `id` is content-addressed from the unordered transaction-id pair, so
/// re-detecting the same pair on any device upserts the same row
/// (idempotent convergence). Dismiss / merge / unmerge delete the
/// record; there is no negative-assertion tombstone. A suggestion always
/// contains exactly two transaction ids.
struct TransferSuggestion: Sendable, Identifiable, Hashable {
  let id: UUID
  let transactionIds: Set<UUID>
  let suggestedAt: Date

  init(transactionIds: Set<UUID>, suggestedAt: Date) {
    precondition(
      transactionIds.count == 2,
      "TransferSuggestion must contain exactly two transaction ids; got \(transactionIds.count)")
    self.transactionIds = transactionIds
    self.suggestedAt = suggestedAt
    self.id = Self.contentAddressedID(for: transactionIds)
  }

  /// The counterpart transaction id in this pair, or `nil` if
  /// `transactionID` is not a member.
  func counterpart(of transactionID: UUID) -> UUID? {
    guard transactionIds.contains(transactionID) else { return nil }
    return transactionIds.first { $0 != transactionID }
  }

  /// The content-addressed id this suggestion carries, derived from the
  /// unordered transaction-id set. Exposed so callers can build an O(1)
  /// membership / lookup set keyed by id.
  static func contentAddressedID(for transactionIds: Set<UUID>) -> UUID {
    let ordered = transactionIds.map(\.uuidString).sorted().joined(separator: ":")
    return UUID.deterministic(from: "transfer-suggestion:\(ordered)")
  }
}

// `id` is content-addressed from `transactionIds`, so it is derived,
// not encoded: persisting it would let the stored value drift from the
// pair it is supposed to identify. Decode rebuilds it through the
// designated initialiser, which also re-checks the two-id invariant.
extension TransferSuggestion: Codable {
  private enum CodingKeys: String, CodingKey {
    case transactionIds
    case suggestedAt
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      transactionIds: try container.decode(Set<UUID>.self, forKey: .transactionIds),
      suggestedAt: try container.decode(Date.self, forKey: .suggestedAt))
  }
}

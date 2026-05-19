import Foundation

extension TransferSuggestionRow {
  /// The CloudKit recordType on the wire for this record. Frozen contract.
  static let recordType = "TransferSuggestionRecord"

  /// Canonical CloudKit `recordName` for a UUID-keyed transfer suggestion.
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  init(domain: TransferSuggestion) {
    let sorted = domain.transactionIds.sorted { $0.uuidString < $1.uuidString }
    self.id = domain.id
    self.recordName = Self.recordName(for: domain.id)
    precondition(
      sorted.count == 2,
      "TransferSuggestion must contain exactly two transaction ids; got \(sorted.count)")
    self.transactionIdA = sorted[0]
    self.transactionIdB = sorted[1]
    self.suggestedAt = domain.suggestedAt
    self.encodedSystemFields = nil
  }

  func toDomain() -> TransferSuggestion {
    TransferSuggestion(
      transactionIds: [transactionIdA, transactionIdB], suggestedAt: suggestedAt)
  }
}

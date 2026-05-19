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

  /// Maps back to the domain value. `id` is recomputed from the pair via content-addressing; a divergent stored `id` (which a well-formed record never has) trips the debug assertion.
  func toDomain() -> TransferSuggestion {
    let result = TransferSuggestion(
      transactionIds: [transactionIdA, transactionIdB],
      suggestedAt: suggestedAt)
    assert(
      result.id == id,
      "TransferSuggestionRow.id \(id) diverges from the content-addressed id "
        + "\(result.id) of its transaction pair")
    return result
  }
}

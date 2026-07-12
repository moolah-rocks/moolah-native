// Backends/GRDB/Records/InvestmentValueRow+Mapping.swift

import Foundation

extension InvestmentValueRow {
  /// The CloudKit recordType on the wire. Frozen contract.
  static let recordType = "InvestmentValueRecord"

  /// Canonical CloudKit `recordName` for a UUID-keyed investment value.
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }
}

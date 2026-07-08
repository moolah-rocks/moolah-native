// Backends/GRDB/Records/TaxOwnerRow+Mapping.swift

import Foundation

extension TaxOwnerRow {
  static let recordType = "TaxOwnerRecord"

  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  init(domain owner: TaxOwner) {
    self.id = owner.id
    self.recordName = Self.recordName(for: owner.id)
    self.name = owner.name
    self.kind = owner.kind.rawValue
    self.encodedSystemFields = nil
  }

  func toDomain() -> TaxOwner {
    TaxOwner(id: id, name: name, kind: TaxOwnerKind(rawValue: kind) ?? .individual)
  }
}

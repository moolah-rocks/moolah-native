// Backends/GRDB/Records/CategoryRow+Mapping.swift

import Foundation

extension CategoryRow {
  /// The CloudKit recordType on the wire for this record. Frozen contract.
  static let recordType = "CategoryRecord"

  /// Canonical CloudKit `recordName` for a UUID-keyed category.
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  init(domain: Moolah.Category) {
    self.id = domain.id
    self.recordName = Self.recordName(for: domain.id)
    self.name = domain.name
    self.parentId = domain.parentId
    self.isTaxReportable = domain.isTaxReportable
    self.taxOwnerIdsEncoded = TaxOwnerIDListCoding.encode(domain.taxOwnerIds)
    self.encodedSystemFields = nil
  }

  func toDomain(taxOwnerIds: [UUID] = []) -> Moolah.Category {
    Moolah.Category(
      id: id,
      name: name,
      parentId: parentId,
      isTaxReportable: isTaxReportable,
      taxOwnerIds: taxOwnerIds.isEmpty
        ? TaxOwnerIDListCoding.decode(taxOwnerIdsEncoded) : taxOwnerIds)
  }
}

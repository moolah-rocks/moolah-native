// Backends/GRDB/Records/ProfileRow+Mapping.swift

import Foundation

extension ProfileRow {
  /// Frozen CloudKit wire name. Identical to the string the SwiftData
  /// `ProfileRecord` used so the existing `profile-index` zone resolves
  /// both record types to the same wire contract.
  static let recordType = "ProfileRecord"

  /// Canonical CloudKit `recordName` for a UUID-keyed profile. Mirrors
  /// the shape (`"<recordType>|<uuid>"`) used everywhere else in the
  /// sync layer (`Backends/CloudKit/Sync/CKRecordIDRecordName.swift`).
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  /// Builds a row from a domain `Profile`. `encodedSystemFields` is set
  /// to `nil`; the repository preserves any pre-existing blob inside
  /// its write closure so a cross-device upsert never strips the
  /// CKRecord change tag.
  init(domain profile: Profile) {
    self.id = profile.id
    self.recordName = ProfileRow.recordName(for: profile.id)
    self.label = profile.label
    self.currencyCode = profile.currencyCode
    self.financialYearStartMonth = profile.financialYearStartMonth
    self.createdAt = profile.createdAt
    self.encodedSystemFields = nil
    self.dataFormatVersion = profile.dataFormatVersion
    self.defaultTaxOwnerId = profile.defaultTaxOwnerId
  }

  /// No data is transformed or synthesised at the mapping boundary —
  /// the round-trip is total, so the only source of divergence between
  /// the returned `Profile` and the original is an out-of-band DB edit.
  func toDomain() -> Profile {
    Profile(
      id: id,
      label: label,
      currencyCode: currencyCode,
      financialYearStartMonth: financialYearStartMonth,
      defaultTaxOwnerId: defaultTaxOwnerId,
      createdAt: createdAt,
      dataFormatVersion: dataFormatVersion)
  }
}

// Backends/GRDB/ProfileIndexSchema+DefaultTaxOwner.swift

import Foundation
import GRDB

extension ProfileIndexSchema {
  /// v11 — adds the profile-level default tax owner. The owner row itself
  /// lives in the per-profile database; this column is only the stable id used
  /// whenever accounts/categories have no explicit owner assignment.
  /// Frozen v11 derivation for the profile's implicit default tax-owner id.
  /// Keep migration code independent from the `TaxOwner` domain model: shipped
  /// migrations are append-only contracts, while domain model helpers can move.
  static func defaultTaxOwnerId(for profileId: UUID) -> UUID {
    UUID.deterministic(from: "tax-owner:default:\(profileId.uuidString)")
  }

  static func addDefaultTaxOwner(_ database: Database) throws {
    try database.execute(
      sql: """
        ALTER TABLE profile
          ADD COLUMN default_tax_owner_id BLOB;
        """)

    let rows = try Row.fetchAll(database, sql: "SELECT id FROM profile")
    for row in rows {
      guard let profileId = row["id"] as UUID? else { continue }
      try database.execute(
        sql: "UPDATE profile SET default_tax_owner_id = ? WHERE id = ?",
        arguments: [Self.defaultTaxOwnerId(for: profileId), profileId])
    }
  }
}

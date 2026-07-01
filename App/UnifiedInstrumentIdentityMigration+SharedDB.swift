// App/UnifiedInstrumentIdentityMigration+SharedDB.swift

import Foundation
import GRDB

extension UnifiedInstrumentIdentityMigration {
  /// Sets `alias_of` on every retired shared-registry row.
  /// Raw SQL — `alias_of` is a local-only column outside `InstrumentRow.CodingKeys`.
  /// Idempotent: writing the same value twice is a no-op (UPDATE sets the column
  /// to a value it already holds). All writes share one transaction so a
  /// mid-step throw rolls the shared DB back unchanged.
  func applyAliasStep(mapping: [String: String]) async throws {
    guard !mapping.isEmpty else { return }
    try await profileIndexDatabase.write { database in
      for (retired, canonical) in mapping {
        try database.execute(
          sql: "UPDATE instrument SET alias_of = ? WHERE id = ?",
          arguments: [canonical, retired])
      }
    }
  }
}

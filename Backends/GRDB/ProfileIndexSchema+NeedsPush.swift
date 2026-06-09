import Foundation
import GRDB

extension ProfileIndexSchema {
  /// v4 — adds the local-only `needs_push` dirty flag to the `profile`
  /// table (mirrors the per-profile v17 migration; see
  /// `ProfileSchema+NeedsPush.swift`). Instrument rows live in the shared
  /// registry and are out of scope.
  static func addNeedsPush(_ database: Database) throws {
    try database.execute(
      sql: "ALTER TABLE profile ADD COLUMN needs_push INTEGER NOT NULL DEFAULT 0;")
  }
}

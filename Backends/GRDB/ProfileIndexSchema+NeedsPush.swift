import Foundation
import GRDB

extension ProfileIndexSchema {
  /// v4 — adds the local-only `needs_push` dirty flag to the `profile`
  /// table (mirrors the per-profile v17 migration; see
  /// `ProfileSchema+NeedsPush.swift`). Instrument rows live in the shared
  /// registry and are out of scope.
  /// `needs_push` is a boolean (0/1), so the column carries a
  /// `CHECK (needs_push IN (0, 1))` (matching the v6 `valuation_mode`
  /// precedent and the per-profile v17 migration). String literal — no
  /// interpolation — per `guides/DATABASE_CODE_GUIDE.md` §4.
  static func addNeedsPush(_ database: Database) throws {
    try database.execute(
      sql: "ALTER TABLE profile ADD COLUMN needs_push INTEGER NOT NULL DEFAULT 0 "
        + "CHECK (needs_push IN (0, 1));")
  }
}

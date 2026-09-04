import Foundation
import GRDB

extension ProfileSchema {
  /// v30 — indexes the import-origin discriminator and timestamp used by
  /// Recently Added. Equality on origin kind leads the range predicate on
  /// imported-at; SQLite can also use the index for the legacy NULL-kind arm.
  static func addTransactionImportOriginIndex(_ database: Database) throws {
    try database.execute(
      sql: """
        CREATE INDEX IF NOT EXISTS transaction_by_import_origin
            ON "transaction"(import_origin_kind, import_origin_imported_at);
        """)
  }
}

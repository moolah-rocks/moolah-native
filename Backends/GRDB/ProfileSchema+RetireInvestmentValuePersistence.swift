import GRDB

extension ProfileSchema {
  /// v25 removes the retired local snapshot representation. CloudKit record
  /// deletion intents are journalled before the table disappears, in the same
  /// migration transaction, so they survive termination and sync-state resets.
  static func retireInvestmentValuePersistence(_ database: Database) throws {
    try database.execute(
      sql: """
        INSERT OR REPLACE INTO deletion_journal
          (zone_name, record_name, record_type, queued_at)
        SELECT
          '@profile-data', record_name, 'InvestmentValueRecord',
          CAST(strftime('%s', 'now') AS REAL)
        FROM investment_value;

        DROP INDEX iv_by_account_date_value;
        DROP TABLE investment_value;

        ALTER TABLE account DROP COLUMN valuation_mode;
        """)
  }
}

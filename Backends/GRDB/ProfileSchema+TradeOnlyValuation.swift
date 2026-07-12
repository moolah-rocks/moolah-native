import GRDB

extension ProfileSchema {
  /// v24 migration body. Legacy snapshot rows remain intact, but every
  /// account is normalised to the only runtime valuation mode.
  static func migrateToTradeOnlyValuation(_ database: Database) throws {
    try database.execute(
      sql: """
        UPDATE account
        SET valuation_mode = 'calculatedFromTrades'
        WHERE valuation_mode <> 'calculatedFromTrades'
        """)
  }
}

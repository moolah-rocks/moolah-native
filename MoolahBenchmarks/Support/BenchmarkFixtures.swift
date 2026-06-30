import Foundation
import GRDB

@testable import Moolah

// MARK: - Scale

/// Defines the scale multiplier for benchmark fixture generation.
struct BenchmarkScale: Sendable {
  let transactions: Int
  let accounts: Int
  let categories: Int
  let earmarks: Int
  let investmentValues: Int
  /// Number of accounts designated as investment type (placed at the end).
  let investmentAccounts: Int

  static let oneX = BenchmarkScale(
    transactions: 18_662,
    accounts: 31,
    categories: 158,
    earmarks: 21,
    investmentValues: 2_711,
    investmentAccounts: 6
  )

  static let twoX = BenchmarkScale(
    transactions: 37_324,
    accounts: 62,
    categories: 316,
    earmarks: 42,
    investmentValues: 5_422,
    investmentAccounts: 12
  )
}

// MARK: - BenchmarkFixtures

/// Generates realistic benchmark datasets matching the live iCloud profile distribution.
///
/// Real data profile (1x):
/// - 18,662 transactions across 31 accounts (top 3 hold ~85%)
/// - 158 categories, 21 earmarks, 2,711 investment values
/// - ~0.2% scheduled transactions
enum BenchmarkFixtures {

  // MARK: - Well-Known IDs

  /// The 3 heavy accounts that hold ~85% of transactions.
  /// Transaction distribution: ~38% heavy0, ~32% heavy1, ~16% heavy2, ~14% others.
  static let heavyAccountIds: [UUID] = [
    "00000000-BE00-0000-0000-000000000001",
    "00000000-BE00-0000-0000-000000000002",
    "00000000-BE00-0000-0000-000000000003",
  ].map { uuidString in
    guard let uuid = UUID(uuidString: uuidString) else {
      preconditionFailure("Invalid hard-coded heavy account UUID: \(uuidString)")
    }
    return uuid
  }

  /// The single busiest account (~38% of all transactions).
  static var heavyAccountId: UUID { heavyAccountIds[0] }

  // MARK: - Seeding

  /// Seeds a complete benchmark dataset into the given database.
  ///
  /// - Parameters:
  ///   - scale: The dataset scale (`.oneX` for real-data-sized, `.twoX` for double).
  ///   - database: An in-memory GRDB writer to populate.
  static func seed(scale: BenchmarkScale, in database: any DatabaseWriter) {
    let instrument = Instrument.defaultTestInstrument

    // Note: `instrument` is fiat (.AUD) and resolves as ambient from the
    // shared profile-index registry — no per-profile InstrumentRow insert is
    // needed. The per-profile `instrument` table was removed by migration
    // `v10_drop_shared_instrument_legacy`.
    expecting("benchmark fixtures save failed") {
      try database.write { database in
        let accountIds = seedAccounts(scale: scale, database: database)
        let categoryIds = seedCategories(scale: scale, database: database)
        let earmarkIds = seedEarmarks(scale: scale, database: database, instrument: instrument)
        seedTransactions(
          scale: scale,
          ids: SeedIds(accounts: accountIds, categories: categoryIds, earmarks: earmarkIds),
          database: database,
          instrument: instrument
        )
        seedInvestmentValues(
          scale: scale,
          accountIds: accountIds,
          database: database,
          instrument: instrument
        )
      }
    }
  }
}

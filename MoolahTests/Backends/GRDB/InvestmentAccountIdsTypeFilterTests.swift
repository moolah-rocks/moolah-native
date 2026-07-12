import Foundation
import GRDB
import Testing

@testable import Moolah

/// The daily-balance investment-account loader classifies by all
/// *investment-like* account types (`investment`, `crypto`, `exchange`),
/// not only the literal `type = 'investment'`. A crypto or exchange account
/// missing from these sets leaks into the bank-balance (`.balance`) sum,
/// overstating current funds and understating investments.
@Suite("Investment-account id loader covers every investment-like type")
struct InvestmentAccountIdsTypeFilterTests {
  @Test("returns every investment-like account")
  func loaderCoversInvestmentLikeTypes() throws {
    let queue = try makeAccountsQueue()
    let ids = try queue.read { database in
      try GRDBAnalysisRepository.fetchInvestmentAccountIds(database: database)
    }
    #expect(ids == Set(Self.investmentLikeIds))
  }

  // One investment, one crypto, and one exchange account. The bank control
  // must never appear in the result.
  private static let investmentLikeIds = [UUID(), UUID(), UUID()]
  private static let bankId = UUID()

  private func makeAccountsQueue() throws -> DatabaseQueue {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue)
    try queue.write { database in
      for seed in Self.seeds {
        try database.execute(
          sql: """
            INSERT INTO account
              (id, record_name, name, type, instrument_id, position,
               is_hidden)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            seed.id, "AccountRecord|\(seed.id)", "n", seed.type, "AUD", 0, 0,
          ])
      }
    }
    return queue
  }

  /// One account per relevant type, plus a bank control that must never appear.
  private struct Seed {
    let id: UUID
    let type: String
  }

  private static let seeds: [Seed] = [
    Seed(id: investmentLikeIds[0], type: "investment"),
    Seed(id: investmentLikeIds[1], type: "crypto"),
    Seed(id: investmentLikeIds[2], type: "exchange"),
    Seed(id: bankId, type: "bank"),
  ]
}

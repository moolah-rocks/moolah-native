import Foundation
import GRDB
import Testing

@testable import Moolah

/// The daily-balance investment-account loaders split accounts by
/// valuation mode — `fetchInvestmentAccountIds` owns the recorded-value
/// snapshot fold, `fetchTradesModeInvestmentAccountIds` owns the
/// trades-mode position valuation. Both must classify by the
/// *investment-like* account types (`investment`, `crypto`, `exchange`),
/// not the literal `type = 'investment'`. A crypto or exchange account
/// missing from these sets leaks into the bank-balance (`.balance`) sum,
/// overstating current funds and understating investments.
@Suite("Investment-account id loaders filter by investment-like type and mode")
struct InvestmentAccountIdsModeFilterTests {
  @Test("recorded-value loader returns every investment-like recordedValue account")
  func recordedValueLoaderCoversInvestmentLikeTypes() throws {
    let queue = try makeAccountsQueue()
    let ids = try queue.read { database in
      try GRDBAnalysisRepository.fetchInvestmentAccountIds(database: database)
    }
    #expect(ids == Set(Self.recordedInvestmentLikeIds))
  }

  @Test("trades-mode loader returns every investment-like calculatedFromTrades account")
  func tradesModeLoaderCoversInvestmentLikeTypes() throws {
    let queue = try makeAccountsQueue()
    let ids = try queue.read { database in
      try GRDBAnalysisRepository.fetchTradesModeInvestmentAccountIds(database: database)
    }
    #expect(ids == Set(Self.tradesInvestmentLikeIds))
  }

  // The investment-like ids expected from each loader: one investment,
  // one crypto, one exchange account per valuation mode. The bank
  // control must never appear in either set.
  private static let recordedInvestmentLikeIds = [UUID(), UUID(), UUID()]
  private static let tradesInvestmentLikeIds = [UUID(), UUID(), UUID()]
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
               is_hidden, valuation_mode)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
          arguments: [
            seed.id, "AccountRecord|\(seed.id)", "n", seed.type, "AUD", 0, 0, seed.mode,
          ])
      }
    }
    return queue
  }

  /// One account per (type, mode) combination that matters, plus a bank
  /// control that must never appear in either set.
  private struct Seed {
    let id: UUID
    let type: String
    let mode: String
  }

  private static let seeds: [Seed] = [
    Seed(id: recordedInvestmentLikeIds[0], type: "investment", mode: "recordedValue"),
    Seed(id: recordedInvestmentLikeIds[1], type: "crypto", mode: "recordedValue"),
    Seed(id: recordedInvestmentLikeIds[2], type: "exchange", mode: "recordedValue"),
    Seed(id: tradesInvestmentLikeIds[0], type: "investment", mode: "calculatedFromTrades"),
    Seed(id: tradesInvestmentLikeIds[1], type: "crypto", mode: "calculatedFromTrades"),
    Seed(id: tradesInvestmentLikeIds[2], type: "exchange", mode: "calculatedFromTrades"),
    Seed(id: bankId, type: "bank", mode: "recordedValue"),
  ]
}

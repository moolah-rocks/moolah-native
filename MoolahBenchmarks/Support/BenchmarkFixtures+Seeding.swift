import Foundation
import GRDB

@testable import Moolah

// Private seeding helpers for `BenchmarkFixtures`. All members are
// `static` on the enum and `internal` to the benchmark target; the only
// entry point is `BenchmarkFixtures.seed`.
extension BenchmarkFixtures {

  // MARK: - Private Helpers

  /// Deterministic UUID from a namespace and index.
  static func deterministicUUID(namespace: UInt8, index: Int) -> UUID {
    // Build a UUID with the namespace byte in position 0 and index bytes in positions 12-15.
    let idx = UInt32(index)
    let uuidString = String(
      format: "%02X000000-BE00-4000-A000-%012X",
      namespace, idx
    )
    guard let uuid = UUID(uuidString: uuidString) else {
      preconditionFailure("deterministicUUID produced an invalid UUID string: \(uuidString)")
    }
    return uuid
  }

  static func seedAccounts(
    scale: BenchmarkScale,
    database: Database
  ) -> [UUID] {
    var ids: [UUID] = []
    seedHeavyAccounts(scale: scale, into: &ids, database: database)
    seedRegularAccounts(scale: scale, into: &ids, database: database)
    seedInvestmentAccounts(scale: scale, into: &ids, database: database)
    return ids
  }

  private static func seedHeavyAccounts(
    scale: BenchmarkScale,
    into ids: inout [UUID],
    database: Database
  ) {
    for i in 0..<min(3, scale.accounts) {
      let id = heavyAccountIds[i]
      ids.append(id)
      let account = Account(
        id: id,
        name: "Heavy Account \(i)",
        type: .bank,
        instrument: .defaultTestInstrument,
        position: i
      )
      expecting("benchmark account insert failed") {
        try AccountRow(domain: account).insert(database)
      }
    }
  }

  private static func seedRegularAccounts(
    scale: BenchmarkScale,
    into ids: inout [UUID],
    database: Database
  ) {
    let nonInvestmentRemaining = scale.accounts - 3 - scale.investmentAccounts
    for i in 0..<nonInvestmentRemaining {
      let id = deterministicUUID(namespace: 0x01, index: i)
      ids.append(id)
      // Alternate between bank, credit card, and asset.
      let accountType: AccountType =
        switch i % 3 {
        case 0: .bank
        case 1: .creditCard
        default: .asset
        }
      let account = Account(
        id: id,
        name: "Account \(i + 3)",
        type: accountType,
        instrument: .defaultTestInstrument,
        position: i + 3
      )
      expecting("benchmark account insert failed") {
        try AccountRow(domain: account).insert(database)
      }
    }
  }

  private static func seedInvestmentAccounts(
    scale: BenchmarkScale,
    into ids: inout [UUID],
    database: Database
  ) {
    for i in 0..<scale.investmentAccounts {
      let id = deterministicUUID(namespace: 0x02, index: i)
      ids.append(id)
      let account = Account(
        id: id,
        name: "Investment \(i)",
        type: .investment,
        instrument: .defaultTestInstrument,
        position: scale.accounts - scale.investmentAccounts + i
      )
      expecting("benchmark account insert failed") {
        try AccountRow(domain: account).insert(database)
      }
    }
  }

  static func seedCategories(
    scale: BenchmarkScale,
    database: Database
  ) -> [UUID] {
    var ids: [UUID] = []
    for i in 0..<scale.categories {
      let id = deterministicUUID(namespace: 0x03, index: i)
      ids.append(id)
      // ~20% are child categories (have a parent).
      let parentId: UUID? =
        (i >= 10 && i.isMultiple(of: 5))
        ? ids[i / 5]
        : nil
      let category = Moolah.Category(id: id, name: "Category \(i)", parentId: parentId)
      expecting("benchmark category insert failed") {
        try CategoryRow(domain: category).insert(database)
      }
    }
    return ids
  }

  static func seedEarmarks(
    scale: BenchmarkScale,
    database: Database,
    instrument: Instrument
  ) -> [UUID] {
    var ids: [UUID] = []
    for i in 0..<scale.earmarks {
      let id = deterministicUUID(namespace: 0x04, index: i)
      ids.append(id)
      // Half have savings targets.
      let savingsGoal: InstrumentAmount? =
        i.isMultiple(of: 2)
        ? InstrumentAmount(quantity: Decimal((i + 1) * 100), instrument: instrument)
        : nil
      let earmark = Earmark(
        id: id,
        name: "Earmark \(i)",
        instrument: instrument,
        position: i,
        savingsGoal: savingsGoal)
      expecting("benchmark earmark insert failed") {
        try EarmarkRow(domain: earmark).insert(database)
      }
    }
    return ids
  }

  /// Bundled identifier sets passed to `seedTransactions`. Holds the
  /// account, category, and earmark UUIDs produced by the preceding
  /// seeding passes so the transaction seeder can reference them
  /// without threading three separate `[UUID]` parameters through its
  /// signature.
  struct SeedIds {
    let accounts: [UUID]
    let categories: [UUID]
    let earmarks: [UUID]
  }
}

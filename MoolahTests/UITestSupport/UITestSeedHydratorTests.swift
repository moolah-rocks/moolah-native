import Foundation
import GRDB
import XCTest

@testable import Moolah

/// Contract tests for `UITestSeedHydrator` — the code path that
/// `MoolahApp` uses when launched with `--ui-testing` to populate an
/// in-memory `ProfileContainerManager` from a named `UITestSeed`.
///
/// Hydration logic is deterministic: every call produces records with the
/// same UUIDs and values taken from `UITestFixtures`, regardless of when it
/// runs. These tests guard that contract so UI tests can reference fixtures
/// symbolically without worrying about non-determinism.
///
/// Both the profile index (`profile-index.sqlite`) and per-profile
/// records (`data.sqlite`) are GRDB-backed; the assertions below read
/// from the corresponding `ProfileRow` / `*Row` tables.
@MainActor
final class UITestSeedHydratorTests: XCTestCase {
  private var _containerManager: ProfileContainerManager?
  private var containerManager: ProfileContainerManager {
    guard let manager = _containerManager else {
      fatalError("setUp must initialise containerManager before tests run")
    }
    return manager
  }

  override func setUp() async throws {
    try await super.setUp()
    _containerManager = try ProfileContainerManager.forTesting()
  }

  override func tearDown() async throws {
    _containerManager = nil
    try await super.tearDown()
  }

  // MARK: - Profile index (GRDB)

  func testHydrateTradeBaselineSeedsTheProfile() async throws {
    _ = try UITestSeedHydrator.hydrate(.tradeBaseline, into: containerManager)

    let profiles = try await containerManager.profileIndexRepository.fetchAll()
    XCTAssertEqual(profiles.count, 1, "expected exactly one seeded profile")
    let profile = try XCTUnwrap(profiles.first)
    XCTAssertEqual(profile.id, UITestFixtures.TradeBaseline.profileId)
    XCTAssertEqual(profile.label, UITestFixtures.TradeBaseline.profileLabel)
    XCTAssertEqual(profile.currencyCode, UITestFixtures.TradeBaseline.profileCurrencyCode)
  }

  func testHydrateReturnsSeededProfile() throws {
    let profile = try XCTUnwrap(
      try UITestSeedHydrator.hydrate(.tradeBaseline, into: containerManager))

    XCTAssertEqual(profile.id, UITestFixtures.TradeBaseline.profileId)
    XCTAssertEqual(profile.currencyCode, UITestFixtures.TradeBaseline.profileCurrencyCode)
  }

  // MARK: - Per-profile data (GRDB)

  func testHydrateTradeBaselineSeedsTheAccounts() throws {
    let profile = try XCTUnwrap(
      try UITestSeedHydrator.hydrate(.tradeBaseline, into: containerManager))
    let database = try containerManager.database(for: profile.id)

    let accounts = try database.read { database in try AccountRow.fetchAll(database) }
    XCTAssertEqual(
      accounts.count, 4,
      "expected checking + brokerage + USD + second position-valued brokerage"
    )
    let ids = Set(accounts.map(\.id))
    XCTAssertEqual(
      ids,
      [
        UITestFixtures.TradeBaseline.checkingAccountId,
        UITestFixtures.TradeBaseline.brokerageAccountId,
        UITestFixtures.TradeBaseline.usdAccountId,
        UITestFixtures.TradeBaseline.tradesBrokerageAccountId,
      ]
    )
    let usd = try XCTUnwrap(
      accounts.first { $0.id == UITestFixtures.TradeBaseline.usdAccountId }
    )
    XCTAssertEqual(usd.instrumentId, UITestFixtures.TradeBaseline.usdAccountInstrumentCode)

  }

  func testHydrateTradeBaselineSeedsTheTradeTransaction() throws {
    let profile = try XCTUnwrap(
      try UITestSeedHydrator.hydrate(.tradeBaseline, into: containerManager))
    let database = try containerManager.database(for: profile.id)
    let tradeId = UITestFixtures.TradeBaseline.bhpPurchaseId

    let trade = try XCTUnwrap(
      try database.read { database in try TransactionRow.fetchOne(database, key: tradeId) },
      "trade transaction must exist"
    )
    XCTAssertEqual(trade.payee, UITestFixtures.TradeBaseline.bhpPurchasePayee)

    let legs = try database.read { database in
      try TransactionLegRow
        .filter(TransactionLegRow.Columns.transactionId == tradeId)
        .fetchAll(database)
    }
    XCTAssertEqual(legs.count, 2, "expected two legs on the trade transaction")
    let accountIds = Set(legs.compactMap(\.accountId))
    XCTAssertEqual(
      accountIds,
      [
        UITestFixtures.TradeBaseline.checkingAccountId,
        UITestFixtures.TradeBaseline.brokerageAccountId,
      ]
    )
  }

  func testHydrateTradeBaselineSeedsTheCategories() throws {
    let profile = try XCTUnwrap(
      try UITestSeedHydrator.hydrate(.tradeBaseline, into: containerManager))
    let database = try containerManager.database(for: profile.id)

    let categories = try database.read { database in try CategoryRow.fetchAll(database) }
    let byId = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
    XCTAssertEqual(
      byId[UITestFixtures.TradeBaseline.groceriesCategoryId]?.name,
      UITestFixtures.TradeBaseline.groceriesCategoryName)
    XCTAssertEqual(
      byId[UITestFixtures.TradeBaseline.gymCategoryId]?.name,
      UITestFixtures.TradeBaseline.gymCategoryName)
  }

  func testHydrateTradeBaselineSeedsTheCustomSplitTransaction() throws {
    let profile = try XCTUnwrap(
      try UITestSeedHydrator.hydrate(.tradeBaseline, into: containerManager))
    let database = try containerManager.database(for: profile.id)
    let splitId = UITestFixtures.TradeBaseline.splitShopId

    let split = try XCTUnwrap(
      try database.read { database in try TransactionRow.fetchOne(database, key: splitId) },
      "custom split transaction must exist"
    )
    XCTAssertEqual(split.payee, UITestFixtures.TradeBaseline.splitShopPayee)

    let legs = try database.read { database in
      try TransactionLegRow
        .filter(TransactionLegRow.Columns.transactionId == splitId)
        .fetchAll(database)
    }
    XCTAssertEqual(legs.count, 2, "split has two legs")
    let accountIds = Set(legs.compactMap(\.accountId))
    XCTAssertEqual(
      accountIds,
      [UITestFixtures.TradeBaseline.checkingAccountId],
      "both legs share Checking — drives isCustom == true"
    )
    XCTAssertTrue(
      legs.allSatisfy { $0.type == TransactionType.expense.rawValue },
      "both legs are expense"
    )
  }

  func testHydrateTradeBaselineSeedsTheHistoricalPayees() throws {
    let profile = try XCTUnwrap(
      try UITestSeedHydrator.hydrate(.tradeBaseline, into: containerManager))
    let database = try containerManager.database(for: profile.id)

    let historicalIds = Set(UITestFixtures.TradeBaseline.historicalPayees.map(\.id))
    let allTransactions = try database.read { database in try TransactionRow.fetchAll(database) }
    let historicals = allTransactions.filter { historicalIds.contains($0.id) }
    XCTAssertEqual(
      historicals.count,
      UITestFixtures.TradeBaseline.historicalPayees.count,
      "expected every historical payee to be seeded"
    )

    let payees = historicals.compactMap(\.payee).sorted()
    XCTAssertEqual(
      payees,
      ["Coles", "Woolworths", "Woolworths", "Woolworths Metro"],
      "historical payees must match fixture list exactly"
    )

    // Each historical has exactly one expense leg on Checking.
    for historical in historicals {
      let txnId = historical.id
      let legs = try database.read { database in
        try TransactionLegRow
          .filter(TransactionLegRow.Columns.transactionId == txnId)
          .fetchAll(database)
      }
      XCTAssertEqual(legs.count, 1, "historical \(historical.payee ?? "?") should have 1 leg")
      XCTAssertEqual(legs.first?.accountId, UITestFixtures.TradeBaseline.checkingAccountId)
      XCTAssertEqual(legs.first?.type, TransactionType.expense.rawValue)
    }
  }

  // MARK: - tradeReady seed

  func testHydrateTradeReadySeedsTheProfile() throws {
    let profile = try XCTUnwrap(
      try UITestSeedHydrator.hydrate(.tradeReady, into: containerManager))

    XCTAssertEqual(profile.id, UITestFixtures.TradeReady.profileId)
    XCTAssertEqual(profile.currencyCode, UITestFixtures.TradeReady.profileCurrencyCode)
  }

  func testHydrateTradeReadySeedsBrokerageAccount() throws {
    let profile = try XCTUnwrap(
      try UITestSeedHydrator.hydrate(.tradeReady, into: containerManager))
    let database = try containerManager.database(for: profile.id)

    let accounts = try database.read { database in try AccountRow.fetchAll(database) }
    XCTAssertEqual(accounts.count, 1, "expected exactly one account")
    let account = try XCTUnwrap(accounts.first)
    XCTAssertEqual(account.id, UITestFixtures.TradeReady.brokerageAccountId)
    XCTAssertEqual(account.name, UITestFixtures.TradeReady.brokerageAccountName)
  }

  func testHydrateTradeReadySeedsVgsaxInstrument() throws {
    _ = try XCTUnwrap(
      try UITestSeedHydrator.hydrate(.tradeReady, into: containerManager))

    // Instrument identity lives on the shared profile-index registry;
    // there is no per-profile `instrument` table.
    let instruments = try containerManager.profileIndexDatabase.read { database in
      try InstrumentRow.fetchAll(database)
    }
    let ids = Set(instruments.map(\.id))
    XCTAssertTrue(
      ids.contains(UITestFixtures.TradeReady.vgsaxInstrumentId),
      "VGS.AX instrument must be registered")
  }

  func testHydrateTradeReadySeedsBrokerageCategory() throws {
    let profile = try XCTUnwrap(
      try UITestSeedHydrator.hydrate(.tradeReady, into: containerManager))
    let database = try containerManager.database(for: profile.id)

    let categories = try database.read { database in try CategoryRow.fetchAll(database) }
    XCTAssertEqual(categories.count, 1, "expected exactly one category")
    let cat = try XCTUnwrap(categories.first)
    XCTAssertEqual(cat.id, UITestFixtures.TradeReady.brokerageCategoryId)
    XCTAssertEqual(cat.name, UITestFixtures.TradeReady.brokerageCategoryName)
  }

  // MARK: - Determinism

  func testHydrateIsIdempotentWhenRunTwice() throws {
    _ = try UITestSeedHydrator.hydrate(.tradeBaseline, into: containerManager)
    let database = try containerManager.database(
      for: UITestFixtures.TradeBaseline.profileId)
    let firstTxnCount = try database.read { database in try TransactionRow.fetchCount(database) }

    // Running hydration again on the same manager should not double-insert.
    _ = try UITestSeedHydrator.hydrate(.tradeBaseline, into: containerManager)
    let secondTxnCount = try database.read { database in try TransactionRow.fetchCount(database) }

    // 1 trade + N historical single-leg expenses + 1 custom multi-leg split.
    let expected = 1 + UITestFixtures.TradeBaseline.historicalPayees.count + 1
    XCTAssertEqual(firstTxnCount, expected)
    XCTAssertEqual(secondTxnCount, expected, "hydration must be idempotent for robust relaunches")
  }
}

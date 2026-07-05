// MoolahTests/Backends/GRDB/CoreFinancialGraphSyncRoundTripTests.swift

import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Verifies that `ProfileDataSyncHandler.applyRemoteChanges` round-trips
/// every core financial graph row type through the GRDB dispatch path.
/// `TransactionRow` and `TransactionLegRow` live in the sibling file
/// `SyncRoundTripTransactionTests.swift`.
///
/// The flow mirrors what CKSyncEngine drives in production: device A
/// produces a CKRecord via `Row.toCKRecord(in:)`, device B's data
/// handler applies it via `applyRemoteChanges`, and we assert the GRDB
/// row on device B matches the source — including the cached
/// `encodedSystemFields` blob bit-for-bit.
@Suite("CKSyncEngine ↔ GRDB round trip — core financial graph")
@MainActor
struct CoreFinancialGraphSyncRoundTripTests {

  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  // MARK: - InstrumentRow

  /// Decommissioned: post-shared-instrument-registry, every
  /// `InstrumentRecord` lives on the profile-index zone. A delivery
  /// to a per-profile zone is straggler state from a not-yet-upgraded
  /// peer device — `applyRemoteChanges` must log-and-skip rather than
  /// write into the per-profile `instrument` table that the v10
  /// follow-up release deletes outright (spec §"Per-profile handler
  /// decommissioning").
  @Test(
    "InstrumentRecord straggler on per-profile zone is silently ignored"
  )
  func instrumentApplyOnPerProfileZoneIsIgnored() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let id = "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    let source = InstrumentRow(
      id: id,
      recordName: id,
      kind: "cryptoToken",
      name: "USD Coin",
      decimals: 6,
      ticker: "USDC",
      exchange: nil,
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      coingeckoId: "usd-coin",
      binanceSymbol: nil,
      encodedSystemFields: nil)
    let ckRecord = source.toCKRecord(in: Self.zoneID)

    let result = harness.handler.applyRemoteChanges(saved: [ckRecord], deleted: [])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed: \(message)")
    }

    // There is no per-profile `instrument` table, so an apply to it
    // is structurally impossible — a strictly stronger guarantee than
    // "the row wasn't written". Assert the table is absent.
    let perProfileInstrumentAbsent = try await harness.database.read { database in
      try
        !(Bool.fetchOne(
          database,
          sql: """
            SELECT EXISTS(
              SELECT 1 FROM sqlite_master WHERE type='table' AND name='instrument')
            """) ?? true)
    }
    #expect(
      perProfileInstrumentAbsent,
      "InstrumentRecord must not be applied to a per-profile instrument table; v10 dropped it")
  }

  // MARK: - CategoryRow

  @Test("Category upsert round-trips through CKSyncEngine apply")
  func categoryRoundTrip() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let id = UUID()
    let source = CategoryRow(domain: Moolah.Category(id: id, name: "Food"))
    let ckRecord = source.toCKRecord(in: Self.zoneID)

    let result = harness.handler.applyRemoteChanges(saved: [ckRecord], deleted: [])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed: \(message)")
    }

    let row = try await harness.database.read { database in
      try CategoryRow.filter(CategoryRow.Columns.id == id).fetchOne(database)
    }
    let resolved = try #require(row)
    #expect(resolved.id == id)
    #expect(resolved.name == "Food")
    #expect(resolved.encodedSystemFields == ckRecord.encodedSystemFields)
  }

  // MARK: - AccountRow

  @Test("Account upsert round-trips through CKSyncEngine apply")
  func accountRoundTrip() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let id = UUID()
    let source = AccountRow(
      domain: Account(
        id: id, name: "Savings", type: .bank, instrument: .USD, position: 3))
    let ckRecord = source.toCKRecord(in: Self.zoneID)

    let result = harness.handler.applyRemoteChanges(saved: [ckRecord], deleted: [])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed: \(message)")
    }

    let row = try await harness.database.read { database in
      try AccountRow.filter(AccountRow.Columns.id == id).fetchOne(database)
    }
    let resolved = try #require(row)
    #expect(resolved.id == id)
    #expect(resolved.name == "Savings")
    #expect(resolved.instrumentId == "USD")
    #expect(resolved.position == 3)
    #expect(resolved.encodedSystemFields == ckRecord.encodedSystemFields)
  }

  // MARK: - EarmarkRow

  @Test("Earmark upsert round-trips through CKSyncEngine apply")
  func earmarkRoundTrip() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let id = UUID()
    let source = EarmarkRow(
      domain: Earmark(id: id, name: "Holiday", instrument: .AUD))
    let ckRecord = source.toCKRecord(in: Self.zoneID)

    let result = harness.handler.applyRemoteChanges(saved: [ckRecord], deleted: [])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed: \(message)")
    }

    let row = try await harness.database.read { database in
      try EarmarkRow.filter(EarmarkRow.Columns.id == id).fetchOne(database)
    }
    let resolved = try #require(row)
    #expect(resolved.id == id)
    #expect(resolved.name == "Holiday")
    #expect(resolved.encodedSystemFields == ckRecord.encodedSystemFields)
  }

  // MARK: - EarmarkBudgetItemRow

  @Test("EarmarkBudgetItem upsert round-trips through CKSyncEngine apply")
  func earmarkBudgetItemRoundTrip() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let earmarkId = UUID()
    let categoryId = UUID()
    let itemId = UUID()
    // FK parents for the budget item must exist before the apply
    // (`earmark_budget_item.earmark_id` and `.category_id` are NOT NULL
    // FKs).
    try await harness.database.write { database in
      try EarmarkRow(
        domain: Earmark(id: earmarkId, name: "Trip", instrument: .AUD)
      ).insert(database)
      try CategoryRow(domain: Moolah.Category(id: categoryId, name: "Food"))
        .insert(database)
    }
    let source = EarmarkBudgetItemRow(
      domain: EarmarkBudgetItem(
        id: itemId, categoryId: categoryId,
        amount: InstrumentAmount(quantity: 50, instrument: .AUD)),
      earmarkId: earmarkId)
    let ckRecord = source.toCKRecord(in: Self.zoneID)

    let result = harness.handler.applyRemoteChanges(saved: [ckRecord], deleted: [])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed: \(message)")
    }

    let row = try await harness.database.read { database in
      try EarmarkBudgetItemRow.filter(EarmarkBudgetItemRow.Columns.id == itemId)
        .fetchOne(database)
    }
    let resolved = try #require(row)
    #expect(resolved.id == itemId)
    #expect(resolved.earmarkId == earmarkId)
    #expect(resolved.categoryId == categoryId)
    #expect(resolved.encodedSystemFields == ckRecord.encodedSystemFields)
  }

  // MARK: - InvestmentValueRow

  @Test("InvestmentValue upsert round-trips through CKSyncEngine apply")
  func investmentValueRoundTrip() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let accountId = UUID()
    let valueId = UUID()
    try await harness.database.write { database in
      try AccountRow(
        domain: Account(
          id: accountId, name: "Brokerage", type: .investment, instrument: .AUD)
      )
      .insert(database)
    }
    let value = InvestmentValue(
      date: Date(timeIntervalSince1970: 1_700_000_000),
      value: InstrumentAmount(quantity: 5000, instrument: .AUD))
    let source = InvestmentValueRow(id: valueId, domain: value, accountId: accountId)
    let ckRecord = source.toCKRecord(in: Self.zoneID)

    let result = harness.handler.applyRemoteChanges(saved: [ckRecord], deleted: [])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed: \(message)")
    }

    let row = try await harness.database.read { database in
      try InvestmentValueRow.filter(InvestmentValueRow.Columns.id == valueId)
        .fetchOne(database)
    }
    let resolved = try #require(row)
    #expect(resolved.id == valueId)
    #expect(resolved.accountId == accountId)
    #expect(resolved.encodedSystemFields == ckRecord.encodedSystemFields)
  }

}

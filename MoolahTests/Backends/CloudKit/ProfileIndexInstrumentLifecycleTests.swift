// MoolahTests/Backends/CloudKit/ProfileIndexInstrumentLifecycleTests.swift

@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Verifies `ProfileIndexSyncHandler`'s conflict-merge and
/// lifecycle-wipe behaviour for `InstrumentRecord`. Dispatch paths
/// live in `ProfileIndexInstrumentDispatchTests`.
@Suite("ProfileIndexSyncHandler — InstrumentRecord conflict + lifecycle")
struct ProfileIndexInstrumentLifecycleTests {
  typealias Harness = ProfileIndexInstrumentTestSupport.Harness

  private static func makeInstrumentRecord(
    in zoneID: CKRecordZone.ID,
    id: String = "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
    name: String = "USD Coin",
    pricingStatus: String = "priced",
    coingeckoId: String? = "usd-coin"
  ) -> CKRecord {
    ProfileIndexInstrumentTestSupport.makeInstrumentRecord(
      in: zoneID,
      id: id,
      name: name,
      pricingStatus: pricingStatus,
      coingeckoId: coingeckoId)
  }

  // MARK: - Conflict dispatch (spam-wins via the conflict path)

  @Test("instrument server-record-changed merge applies spam-wins to local row")
  func instrumentServerRecordChangedAppliesSpamWins() async throws {
    let harness = try Harness()
    // Local: priced. Server: spam, with a fresher coingecko_id.
    try await harness.registry.registerCrypto(
      Instrument.crypto(
        chainId: 1, contractAddress: "0xfff", symbol: "FFF", name: "Fff",
        decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "1:0xfff",
        coingeckoId: "fff-old",
        binanceSymbol: nil))

    let serverRecord = Self.makeInstrumentRecord(
      in: harness.handler.zoneID,
      id: "1:0xfff",
      name: "Fff",
      pricingStatus: "spam",
      coingeckoId: "fff-fresh")

    // Drive the merge directly. `FailedRecordSave` is not publicly
    // constructible, so the full `handleSentRecordZoneChanges` round-
    // trip can't be synthesised in unit tests; the dispatch in that
    // method is a one-line type switch, while the substantive
    // behaviour lives in `applyInstrumentServerRecordChangedMerge`.
    harness.handler.applyInstrumentServerRecordChangedMerge(
      serverRecord: serverRecord)

    let row: InstrumentRow? = try await harness.queue.read { database in
      try InstrumentRow
        .filter(InstrumentRow.Columns.id == "1:0xfff")
        .fetchOne(database)
    }
    let stored = try #require(row)
    #expect(stored.pricingStatus == "spam")
    #expect(stored.coingeckoId == "fff-fresh")
  }

  // MARK: - Lifecycle wipes

  @Test("clearAllSystemFields nulls encoded_system_fields on instrument rows too")
  func clearAllSystemFieldsCoversInstrumentTable() async throws {
    let harness = try Harness()
    try await harness.registry.registerCrypto(
      Instrument.crypto(
        chainId: 1, contractAddress: "0xccc", symbol: "CCC", name: "Ccc",
        decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "1:0xccc",
        coingeckoId: "ccc",
        binanceSymbol: nil))

    try await harness.queue.write { database in
      try database.execute(
        sql: """
          UPDATE instrument SET encoded_system_fields = ?
          WHERE id = ?
          """,
        arguments: [Data([0x00, 0x01, 0x02]), "1:0xccc"])
    }

    harness.handler.clearAllSystemFields()

    let stillSet: Int? = try await harness.queue.read { database in
      try Int.fetchOne(
        database,
        sql:
          "SELECT COUNT(*) FROM instrument WHERE encoded_system_fields IS NOT NULL"
      )
    }
    #expect(stillSet == 0)
  }

  @Test("deleteLocalData wipes profile + instrument + price-cache tables atomically")
  func deleteLocalDataWipesAllProfileIndexTables() async throws {
    let harness = try Harness()

    // Seed every table.
    try await harness.queue.write { database in
      try ProfileRow(
        id: UUID(),
        recordName: "ProfileRecord|x",
        label: "X",
        currencyCode: "AUD",
        financialYearStartMonth: 7,
        createdAt: Date(),
        encodedSystemFields: nil,
        dataFormatVersion: 0
      ).insert(database)
      try database.execute(
        sql:
          "INSERT INTO crypto_price (token_id, date, price_usd) VALUES (?, ?, ?)",
        arguments: ["bitcoin", "2026-05-09", 50_000.0])
      try database.execute(
        sql:
          "INSERT INTO exchange_rate (base, quote, date, rate) VALUES (?, ?, ?, ?)",
        arguments: ["AUD", "USD", "2026-05-09", 0.66])
      try database.execute(
        sql:
          "INSERT INTO stock_price (ticker, date, price) VALUES (?, ?, ?)",
        arguments: ["AAPL.AX", "2026-05-09", 200.0])
    }
    try await harness.registry.registerCrypto(
      Instrument.crypto(
        chainId: 1, contractAddress: "0xeee", symbol: "EEE", name: "Eee",
        decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "1:0xeee",
        coingeckoId: "eee",
        binanceSymbol: nil))

    harness.handler.deleteLocalData()

    let counts: [String: Int] = try await harness.queue.read { database in
      var values: [String: Int] = [:]
      for table in [
        "profile", "instrument",
        "crypto_price", "stock_price",
        "exchange_rate",
      ] {
        values[table] =
          try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM \(table)") ?? -1
      }
      return values
    }
    for (table, count) in counts {
      #expect(count == 0, "\(table) should be empty (was \(count))")
    }
  }
}

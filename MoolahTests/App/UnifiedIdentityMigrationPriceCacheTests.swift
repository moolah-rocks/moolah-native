// MoolahTests/App/UnifiedIdentityMigrationPriceCacheTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

// MARK: - Seeding and query helpers

extension MigrationTestHarness {
  /// Inserts one row per element into `crypto_token_meta` in the shared index DB.
  /// `rows` is an array of `(tokenId, firstTradedOn)` pairs; `firstTradedOn` is
  /// an ISO YYYY-MM-DD string or `nil` when not yet confirmed.
  func seedCryptoMeta(_ rows: [(String, String?)]) async throws {
    try await migration.profileIndexDatabase.write { database in
      for (tokenId, firstTradedOn) in rows {
        try database.execute(
          literal: """
            INSERT INTO crypto_token_meta
                (token_id, symbol, earliest_date, latest_date, first_traded_on)
            VALUES (\(tokenId), 'ETH', '2020-01-01', '2026-01-01', \(firstTradedOn))
            """)
      }
    }
  }

  /// Inserts one dummy price row per `tokenId` into `crypto_price` in the shared
  /// index DB. The date and price are fixed; only the `token_id` column varies.
  func seedCryptoPrice(_ tokenIds: [String]) async throws {
    try await migration.profileIndexDatabase.write { database in
      for tokenId in tokenIds {
        try database.execute(
          literal: """
            INSERT INTO crypto_price (token_id, date, price_usd)
            VALUES (\(tokenId), '2022-01-01', 1000.0)
            """)
      }
    }
  }

  /// Returns `first_traded_on` for the given `tokenId`, or `nil` when the row
  /// does not exist or the column is NULL.
  func firstTradedOn(_ tokenId: String) async throws -> String? {
    try await migration.profileIndexDatabase.read { database in
      try String.fetchOne(
        database,
        sql: "SELECT first_traded_on FROM crypto_token_meta WHERE token_id = ?",
        arguments: [tokenId])
    }
  }

  /// Returns `true` when a `crypto_token_meta` row exists for `tokenId`.
  func cryptoMetaExists(_ tokenId: String) async throws -> Bool {
    try await migration.profileIndexDatabase.read { database in
      let count =
        try Int.fetchOne(
          database,
          sql: "SELECT count(*) FROM crypto_token_meta WHERE token_id = ?",
          arguments: [tokenId]) ?? 0
      return count > 0
    }
  }

  /// Returns the number of `crypto_price` rows for `tokenId`.
  func cryptoPriceCount(_ tokenId: String) async throws -> Int {
    try await migration.profileIndexDatabase.read { database in
      try Int.fetchOne(
        database,
        sql: "SELECT count(*) FROM crypto_price WHERE token_id = ?",
        arguments: [tokenId]) ?? 0
    }
  }
}

// MARK: - Tests

@MainActor
@Suite
struct UnifiedIdentityMigrationPriceCacheTests {
  @Test("price cache: canonical first_traded_on = MIN(canonical, retired); retired caches purged")
  func priceCacheMinAndPurge() async throws {
    let harness = try MigrationTestHarness.make()
    try await harness.seedCryptoMeta([
      ("1:native", "2022-01-01"),
      ("10:native", "2021-06-01"),
      ("8453:native", nil),
    ])
    try await harness.seedCryptoPrice(["1:native", "10:native", "8453:native"])
    let mapping = ["10:native": "1:native", "8453:native": "1:native"]

    try await harness.migration.applyPriceCacheStep(mapping: mapping)

    // Canonical first_traded_on becomes the earliest non-NULL date.
    #expect(try await harness.firstTradedOn("1:native") == "2021-06-01")
    // Retired meta rows are deleted.
    #expect(try await harness.cryptoMetaExists("10:native") == false)
    #expect(try await harness.cryptoMetaExists("8453:native") == false)
    // Retired price rows are deleted.
    #expect(try await harness.cryptoPriceCount("10:native") == 0)
    #expect(try await harness.cryptoPriceCount("8453:native") == 0)
    // Canonical price rows are untouched.
    #expect(try await harness.cryptoPriceCount("1:native") > 0)
  }

  @Test("price cache step is idempotent: second run leaves the same state")
  func priceCacheStepIsIdempotent() async throws {
    let harness = try MigrationTestHarness.make()
    try await harness.seedCryptoMeta([
      ("1:native", "2022-01-01"),
      ("10:native", "2021-06-01"),
    ])
    try await harness.seedCryptoPrice(["1:native", "10:native"])
    let mapping = ["10:native": "1:native"]

    try await harness.migration.applyPriceCacheStep(mapping: mapping)
    try await harness.migration.applyPriceCacheStep(mapping: mapping)

    #expect(try await harness.firstTradedOn("1:native") == "2021-06-01")
    #expect(try await harness.cryptoMetaExists("10:native") == false)
    #expect(try await harness.cryptoPriceCount("10:native") == 0)
    #expect(try await harness.cryptoPriceCount("1:native") > 0)
  }

  @Test("price cache: retired NULL first_traded_on does not overwrite canonical date")
  func nullRetiredDoesNotCorruptCanonicalDate() async throws {
    let harness = try MigrationTestHarness.make()
    // Canonical has a known date; the only retired token has NULL.
    try await harness.seedCryptoMeta([
      ("1:native", "2022-01-01"),
      ("10:native", nil),
    ])
    try await harness.seedCryptoPrice(["1:native", "10:native"])
    let mapping = ["10:native": "1:native"]

    try await harness.migration.applyPriceCacheStep(mapping: mapping)

    // NULL retired must not overwrite the canonical's existing date.
    #expect(try await harness.firstTradedOn("1:native") == "2022-01-01")
    #expect(try await harness.cryptoMetaExists("10:native") == false)
    #expect(try await harness.cryptoPriceCount("10:native") == 0)
  }

  @Test("price cache: empty mapping is a no-op")
  func emptyMappingIsNoOp() async throws {
    let harness = try MigrationTestHarness.make()
    try await harness.seedCryptoMeta([("1:native", "2022-01-01")])
    try await harness.seedCryptoPrice(["1:native"])

    try await harness.migration.applyPriceCacheStep(mapping: [:])

    // Nothing should have changed.
    #expect(try await harness.cryptoMetaExists("1:native") == true)
    #expect(try await harness.cryptoPriceCount("1:native") > 0)
  }
}

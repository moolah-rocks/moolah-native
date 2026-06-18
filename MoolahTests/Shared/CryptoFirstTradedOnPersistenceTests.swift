import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("CryptoFirstTradedOn — Persistence")
struct CryptoFirstTradedOnPersistenceTests {
  private let ethInstrument = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
  )

  private func makeService(
    prices: [String: [String: Decimal]] = [:],
    database: DatabaseQueue
  ) throws -> CryptoPriceService {
    let client = FixedCryptoPriceClient(prices: prices, shouldFail: false)
    return CryptoPriceService(clients: [client], database: database)
  }

  // MARK: - loadCache hydrates firstTradedOn

  /// Seeding `crypto_token_meta` with `first_traded_on = '2024-10-01'` and
  /// calling `loadCache` must surface that value through
  /// `caches[tokenId]?.firstTradedOn`.
  @Test("loadCache hydrates first_traded_on from crypto_token_meta")
  func loadsFirstTradedOn() async throws {
    let database = try ProfileIndexDatabase.openInMemory()

    // Seed a meta row directly — bypasses the client path so we can
    // control the `first_traded_on` value independently.
    try await database.write { database in
      try database.execute(
        sql: """
          INSERT INTO crypto_token_meta
            (token_id, symbol, earliest_date, latest_date, first_traded_on)
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: ["1:native", "ETH", "2024-10-01", "2024-10-01", "2024-10-01"]
      )
    }

    let service = try makeService(database: database)
    try await service.loadCache(tokenId: "1:native")

    let firstTradedOn = await service.caches["1:native"]?.firstTradedOn
    #expect(firstTradedOn == "2024-10-01")
  }

  // MARK: - persistDelta round-trip preserves firstTradedOn

  /// `persistDelta` must not clobber a non-nil `firstTradedOn` to nil.
  /// Seeding the DB with a `first_traded_on` value, loading via
  /// `loadCache`, then calling `persistDelta` must keep the value intact
  /// in the database — verified by a direct row read and a second
  /// `loadCache` call on a fresh service.
  @Test("persistDelta round-trip preserves non-nil firstTradedOn")
  func persistDeltaPreservesFirstTradedOn() async throws {
    let database = try ProfileIndexDatabase.openInMemory()

    // Seed a meta row with first_traded_on so loadCache hydrates it.
    try await database.write { database in
      try database.execute(
        sql: """
          INSERT INTO crypto_token_meta
            (token_id, symbol, earliest_date, latest_date, first_traded_on)
          VALUES (?, ?, ?, ?, ?)
          """,
        arguments: ["1:native", "ETH", "2024-10-01", "2024-10-01", "2024-10-01"]
      )
      try database.execute(
        sql: "INSERT INTO crypto_price (token_id, date, price_usd) VALUES (?, ?, ?)",
        arguments: ["1:native", "2024-10-01", 1600.00]
      )
    }

    let service = try makeService(
      prices: ["1:native": ["2024-10-01": dec("1600.00")]],
      database: database
    )
    // Hydrate the cache from the seeded meta row (firstTradedOn = "2024-10-01").
    try await service.loadCache(tokenId: "1:native")

    let firstTradedOnBefore = await service.caches["1:native"]?.firstTradedOn
    #expect(firstTradedOnBefore == "2024-10-01")

    // Write back via persistDelta with an empty delta (meta row only).
    try await service.persistDelta(tokenId: "1:native", deltaRecords: [])

    // Read the meta row back and assert the column was preserved.
    let stored = try await database.read { database in
      try CryptoTokenMetaRecord
        .filter(CryptoTokenMetaRecord.Columns.tokenId == "1:native")
        .fetchOne(database)
    }
    #expect(stored?.firstTradedOn == "2024-10-01")

    // Verify a fresh service loading the same DB surfaces the value.
    let service2 = try makeService(database: database)
    try await service2.loadCache(tokenId: "1:native")
    let secondFirstTradedOn = await service2.caches["1:native"]?.firstTradedOn
    #expect(secondFirstTradedOn == "2024-10-01")
  }
}

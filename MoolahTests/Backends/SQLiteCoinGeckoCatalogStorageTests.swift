import Foundation
import Testing

@testable import Moolah

/// Class-based suite so `deinit` can deterministically remove the per-test
/// temp directory. Each `@Test` method runs on its own instance, mirroring
/// the XCTest setUp/tearDown pattern from the plan.
@Suite("SQLiteCoinGeckoCatalog storage")
final class SQLiteCoinGeckoCatalogStorageTests {
  private let tempDir: URL

  init() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("catalog-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: tempDir)
  }

  @Test
  func openCreatesFreshSchema() async throws {
    let catalog = try SQLiteCoinGeckoCatalog.make(
      directory: tempDir,
      apiKeyProvider: { nil },
      networking: NetworkingServices())
    let dbURL = tempDir.appendingPathComponent("catalog.sqlite")
    #expect(FileManager.default.fileExists(atPath: dbURL.path))
    let meta = try await catalog.readMetaForTesting()
    #expect(meta.schemaVersion == CoinGeckoCatalogSchema.version)
    #expect(meta.lastFetched == nil)
    #expect(meta.coinsEtag == nil)
    #expect(meta.platformsEtag == nil)
  }

  @Test
  func replaceAllCoinsAndPlatformsCommitsAtomically() async throws {
    let catalog = try SQLiteCoinGeckoCatalog.make(
      directory: tempDir,
      apiKeyProvider: { nil },
      networking: NetworkingServices())
    let coins: [SQLiteCoinGeckoCatalog.RawCoin] = [
      .init(id: "bitcoin", symbol: "BTC", name: "Bitcoin", platforms: [:]),
      .init(
        id: "uniswap", symbol: "UNI", name: "Uniswap",
        platforms: ["ethereum": "0x1F9840a85d5aF5bf1D1762F925BDADdC4201F984"]
      ),
    ]
    let platforms: [SQLiteCoinGeckoCatalog.RawPlatform] = [
      .init(slug: "ethereum", chainId: 1, name: "Ethereum")
    ]
    try await catalog.replaceAllForTesting(coins: coins, platforms: platforms)

    let count = try await catalog.coinCountForTesting()
    #expect(count == 2)
    let platformCount = try await catalog.platformCountForTesting()
    #expect(platformCount == 1)
    let coinPlatformCount = try await catalog.coinPlatformCountForTesting()
    #expect(coinPlatformCount == 1)
  }

  @Test
  func replaceAllReplacesPriorContent() async throws {
    let catalog = try SQLiteCoinGeckoCatalog.make(
      directory: tempDir,
      apiKeyProvider: { nil },
      networking: NetworkingServices())
    let first: [SQLiteCoinGeckoCatalog.RawCoin] = [
      .init(id: "bitcoin", symbol: "BTC", name: "Bitcoin", platforms: [:])
    ]
    let second: [SQLiteCoinGeckoCatalog.RawCoin] = [
      .init(id: "ethereum", symbol: "ETH", name: "Ethereum", platforms: [:]),
      .init(id: "tether", symbol: "USDT", name: "Tether", platforms: [:]),
    ]
    try await catalog.replaceAllForTesting(coins: first, platforms: [])
    try await catalog.replaceAllForTesting(coins: second, platforms: [])

    let count = try await catalog.coinCountForTesting()
    #expect(count == 2)
  }

  @Test
  func constraintFailureIncludesSqliteErrorMessage() async throws {
    let catalog = try SQLiteCoinGeckoCatalog.make(
      directory: tempDir,
      apiKeyProvider: { nil },
      networking: NetworkingServices())
    let withDuplicate: [SQLiteCoinGeckoCatalog.RawCoin] = [
      .init(id: "tether", symbol: "USDT", name: "Tether", platforms: [:]),
      .init(id: "tether", symbol: "USDT", name: "Tether (dup)", platforms: [:]),
    ]
    do {
      try await catalog.replaceAllForTesting(coins: withDuplicate, platforms: [])
      Issue.record("expected constraint failure")
    } catch let CatalogError.sqlite(message) {
      // Extended result codes turn bare `step 19` into the specific
      // `SQLITE_CONSTRAINT_UNIQUE (2067)` plus the human-readable errmsg
      // "UNIQUE constraint failed: coin.coingecko_id". Without both pieces
      // a real-world refresh failure can't be diagnosed from logs alone.
      #expect(message.contains("UNIQUE constraint failed"))
      #expect(message.contains("coin.coingecko_id"))
      #expect(message.contains("2067"))
    } catch {
      Issue.record("unexpected error type: \(error)")
    }
  }

  @Test
  func replaceAllRollsBackOnConstraintFailure() async throws {
    let catalog = try SQLiteCoinGeckoCatalog.make(
      directory: tempDir,
      apiKeyProvider: { nil },
      networking: NetworkingServices())

    // Seed a successful first batch so we have prior state to preserve.
    let first: [SQLiteCoinGeckoCatalog.RawCoin] = [
      .init(id: "bitcoin", symbol: "BTC", name: "Bitcoin", platforms: [:]),
      .init(id: "ethereum", symbol: "ETH", name: "Ethereum", platforms: [:]),
    ]
    try await catalog.replaceAllForTesting(coins: first, platforms: [])
    let seededCount = try await catalog.coinCountForTesting()
    #expect(seededCount == 2)

    // Second batch contains a duplicate id — the UNIQUE constraint on
    // `coingecko_id` fires on the second insert, so `replaceAll`'s catch
    // must ROLLBACK and rethrow.
    let withDuplicate: [SQLiteCoinGeckoCatalog.RawCoin] = [
      .init(id: "tether", symbol: "USDT", name: "Tether", platforms: [:]),
      .init(id: "tether", symbol: "USDT", name: "Tether (dup)", platforms: [:]),
    ]
    await #expect(throws: (any Error).self) {
      try await catalog.replaceAllForTesting(coins: withDuplicate, platforms: [])
    }

    // Rollback restored the prior two coins; without rollback the count
    // would be 0 (the DELETEs ran before the failing INSERT).
    let countAfter = try await catalog.coinCountForTesting()
    #expect(countAfter == 2)
  }

  @Test
  func replaceAllCascadeDeletesOrphanedPlatformRows() async throws {
    let catalog = try SQLiteCoinGeckoCatalog.make(
      directory: tempDir,
      apiKeyProvider: { nil },
      networking: NetworkingServices())

    // Seed a coin WITH a platform row so `coin_platform` is non-empty.
    let withPlatforms: [SQLiteCoinGeckoCatalog.RawCoin] = [
      .init(
        id: "uniswap", symbol: "UNI", name: "Uniswap",
        platforms: ["ethereum": "0x1F9840a85d5aF5bf1D1762F925BDADdC4201F984"]
      )
    ]
    let platforms: [SQLiteCoinGeckoCatalog.RawPlatform] = [
      .init(slug: "ethereum", chainId: 1, name: "Ethereum")
    ]
    try await catalog.replaceAllForTesting(coins: withPlatforms, platforms: platforms)
    let seededCoinPlatforms = try await catalog.coinPlatformCountForTesting()
    #expect(seededCoinPlatforms > 0)

    // Replace with the same coin carrying NO platforms. The `DELETE FROM coin`
    // inside `replaceAll` must cascade to `coin_platform` via the
    // `ON DELETE CASCADE` foreign key — which only fires when the
    // per-connection `PRAGMA foreign_keys = ON` is in force. If FK
    // enforcement lapsed, the orphaned `coin_platform` rows would survive.
    let withoutPlatforms: [SQLiteCoinGeckoCatalog.RawCoin] = [
      .init(id: "uniswap", symbol: "UNI", name: "Uniswap", platforms: [:])
    ]
    try await catalog.replaceAllForTesting(coins: withoutPlatforms, platforms: [])

    let coinPlatformsAfter = try await catalog.coinPlatformCountForTesting()
    #expect(coinPlatformsAfter == 0)
    let coinCountAfter = try await catalog.coinCountForTesting()
    #expect(coinCountAfter == 1)
  }

  @Test
  func schemaVersionMismatchRecreatesFile() async throws {
    let networking = NetworkingServices()
    _ = try SQLiteCoinGeckoCatalog.make(
      directory: tempDir, apiKeyProvider: { nil }, networking: networking)
    let dbURL = tempDir.appendingPathComponent("catalog.sqlite")
    let creationOriginal =
      try FileManager.default.attributesOfItem(atPath: dbURL.path)[.creationDate] as? Date

    let stale = try SQLiteCoinGeckoCatalog.make(
      directory: tempDir, apiKeyProvider: { nil }, networking: networking)
    try await stale.writeMetaSchemaVersionForTesting(999)

    let reopened = try SQLiteCoinGeckoCatalog.make(
      directory: tempDir, apiKeyProvider: { nil }, networking: networking)
    let metaAfter = try await reopened.readMetaForTesting()
    #expect(metaAfter.schemaVersion == CoinGeckoCatalogSchema.version)

    let creationNew =
      try FileManager.default.attributesOfItem(atPath: dbURL.path)[.creationDate] as? Date
    #expect(creationOriginal != creationNew)
  }
}

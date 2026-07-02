// MoolahTests/App/UnifiedIdentityMigrationTestSupport.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Namespace marker (required by CODE_GUIDE §5 file_name rule).
enum UnifiedIdentityMigrationTestSupport {}

// MARK: - MigrationTestHarness

/// Minimal in-memory harness for `UnifiedInstrumentIdentityMigration` mapping
/// tests. Wires a real `GRDBInstrumentRegistryRepository` +
/// `CanonicalInstrumentResolver` over an in-memory profile-index DB.
/// Per-profile dependencies (`dataDatabaseProvider`, `allProfileIds`, `rePush`)
/// are no-op stubs — Task 1 tests cover mapping derivation only.
@MainActor
struct MigrationTestHarness {
  let registry: GRDBInstrumentRegistryRepository
  let resolver: CanonicalInstrumentResolver
  let migration: UnifiedInstrumentIdentityMigration

  static func make() throws -> MigrationTestHarness {
    let database = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let resolver = CanonicalInstrumentResolver()
    let suiteName = "test-migration-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName) ?? .standard
    defaults.removePersistentDomain(forName: suiteName)
    let migration = UnifiedInstrumentIdentityMigration(
      profileIndexDatabase: database,
      dataDatabaseProvider: { _ in try ProfileDatabase.openInMemory() },
      allProfileIds: { [] },
      registry: registry,
      resolver: resolver,
      rePush: { _ in },
      userDefaults: defaults)
    return MigrationTestHarness(registry: registry, resolver: resolver, migration: migration)
  }

  /// Seeds the shared registry with `registrations`, writing each via the
  /// normal `registerCrypto` path. Retired rows (with a provider mapping but
  /// a chain-scoped id that resolves to a different canonical id) are
  /// acceptable; `alias_of` is written separately by Task 2.
  func seedSharedRegistry(_ registrations: [CryptoRegistration]) async throws {
    for registration in registrations {
      try await registry.registerCrypto(registration.instrument, mapping: registration.mapping)
    }
  }
}

// MARK: - Per-profile database cache

/// Stores one in-memory `DatabaseQueue` per profile UUID so the same database
/// is returned to both the test (seeding + assertions) and the migration
/// (`dataDatabaseProvider` closure). Marked `@unchecked Sendable` because
/// all test access is on the main actor; the `@Sendable` closure requirement
/// on `dataDatabaseProvider` requires the captured type to be `Sendable`.
final class ProfileDatabaseCache: @unchecked Sendable {
  private var databases: [UUID: DatabaseQueue] = [:]

  func database(for profileId: UUID) throws -> DatabaseQueue {
    if let existing = databases[profileId] { return existing }
    let queue = try ProfileDatabase.openInMemory()
    databases[profileId] = queue
    return queue
  }
}

// MARK: - Harness factory for profile-rewrite tests

/// Returns a `MigrationTestHarness` whose `dataDatabaseProvider` is backed by
/// `cache`, so seeding and the migration share the same per-profile database.
@MainActor
func makeProfileRewriteHarness() throws -> (
  harness: MigrationTestHarness, cache: ProfileDatabaseCache
) {
  let cache = ProfileDatabaseCache()
  let indexDatabase = try ProfileIndexDatabase.openInMemory()
  let registry = GRDBInstrumentRegistryRepository(database: indexDatabase)
  let resolver = CanonicalInstrumentResolver()
  let suiteName = "test-profile-rewrite-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName) ?? .standard
  defaults.removePersistentDomain(forName: suiteName)
  let migration = UnifiedInstrumentIdentityMigration(
    profileIndexDatabase: indexDatabase,
    dataDatabaseProvider: { profileId in try cache.database(for: profileId) },
    allProfileIds: { [] },
    registry: registry,
    resolver: resolver,
    rePush: { _ in },
    userDefaults: defaults)
  let harness = MigrationTestHarness(registry: registry, resolver: resolver, migration: migration)
  return (harness, cache)
}

// MARK: - Seeding helpers

/// Inserts one row into each of the six FK tables (transaction_leg, earmark,
/// earmark_budget_item, account_group, investment_value) and the defensive
/// account column. All instrument_id columns point at `10:native` (retired).
/// The earmark.savings_target_instrument_id is set to `8453:native` so both
/// retired ids are covered in a two-entry mapping.
/// FK enforcement is OFF after v5_drop_foreign_keys, so parent rows are not
/// required — transaction_id, earmark_id, account_id, and category_id can be
/// arbitrary UUIDs.
func seedRetiredRows(_ database: Database) throws {
  let legId = UUID()
  try database.execute(
    sql:
      "INSERT INTO transaction_leg (id, record_name, transaction_id, instrument_id, quantity, type, sort_order) VALUES (?, ?, ?, '10:native', 100, 'income', 0)",
    arguments: [legId, "TxLeg|\(legId.uuidString)", UUID()])
  let earmarkId = UUID()
  try database.execute(
    sql:
      "INSERT INTO earmark (id, record_name, name, position, is_hidden, instrument_id, savings_target_instrument_id) VALUES (?, ?, 'Savings', 0, 0, '10:native', '8453:native')",
    arguments: [earmarkId, "Earmark|\(earmarkId.uuidString)"])
  let ebiId = UUID()
  try database.execute(
    sql:
      "INSERT INTO earmark_budget_item (id, record_name, earmark_id, category_id, amount, instrument_id) VALUES (?, ?, ?, ?, 500, '10:native')",
    arguments: [ebiId, "EBI|\(ebiId.uuidString)", earmarkId, UUID()])
  let groupId = UUID()
  try database.execute(
    sql:
      "INSERT INTO account_group (id, record_name, name, bucket, instrument_id, position) VALUES (?, ?, 'ETH Wallets', 'investments', '10:native', 0)",
    arguments: [groupId, "AG|\(groupId.uuidString)"])
  let ivId = UUID()
  try database.execute(
    sql:
      "INSERT INTO investment_value (id, record_name, account_id, date, value, instrument_id) VALUES (?, ?, ?, '2024-01-01', 1000, '10:native')",
    arguments: [ivId, "IV|\(ivId.uuidString)", UUID()])
  let acctId = UUID()
  try database.execute(
    sql:
      "INSERT INTO account (id, record_name, name, type, instrument_id, position, is_hidden) VALUES (?, ?, 'ETH Account', 'investment', '10:native', 0, 0)",
    arguments: [acctId, "Acct|\(acctId.uuidString)"])
}

// MARK: - Query helpers

/// Executes a single-column `sql` query against `queue` and returns all rows
/// as strings. For test use only — `sql` must be a hard-coded literal.
func fetchAll(_ sql: String, in queue: DatabaseQueue) async throws -> [String] {
  try await queue.read { database in
    try String.fetchAll(database, sql: sql)
  }
}

/// Returns the count of rows with `needs_push = 1` in `table`. `table` is a
/// SQL identifier and cannot be bound with `?`; the `allowed` allowlist closes
/// the set immediately before interpolation so no dynamic value reaches the SQL
/// (DATABASE_CODE_GUIDE §4). Test use only.
func needsPushCount(_ table: String, in queue: DatabaseQueue) async throws -> Int {
  let allowed: Set<String> = [
    "transaction_leg", "earmark", "earmark_budget_item",
    "account_group", "investment_value", "account",
  ]
  precondition(allowed.contains(table), "needsPushCount: unlisted table '\(table)'")
  return try await queue.read { database in
    try Int.fetchOne(
      database, sql: "SELECT count(*) FROM \(table) WHERE needs_push = 1") ?? 0
  }
}

// MARK: - CryptoRegistration test fixtures

extension CryptoRegistration {
  /// ETH on Ethereum mainnet — canonical (`1:native`).
  static let ethMainnet = CryptoRegistration(
    instrument: .crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
    mapping: CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: "ethereum",
      cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"))

  /// ETH on Optimism — retired cross-chain id (`10:native`).
  static let ethOptimism = CryptoRegistration(
    instrument: .crypto(
      chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
    mapping: CryptoProviderMapping(
      instrumentId: "10:native", coingeckoId: "ethereum",
      cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"))

  /// ETH on Base — retired cross-chain id (`8453:native`).
  static let ethBase = CryptoRegistration(
    instrument: .crypto(
      chainId: 8453, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
    mapping: CryptoProviderMapping(
      instrumentId: "8453:native", coingeckoId: "ethereum",
      cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"))

  /// USDC on Ethereum mainnet — canonical.
  static let usdcMainnet = CryptoRegistration(
    instrument: .crypto(
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC", name: "USD Coin", decimals: 6),
    mapping: CryptoProviderMapping(
      instrumentId: "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      coingeckoId: "usd-coin", cryptocompareSymbol: "USDC", binanceSymbol: "USDCUSDT"))

  /// USDC on Optimism — retired cross-chain id.
  static let usdcOptimism = CryptoRegistration(
    instrument: .crypto(
      chainId: 10,
      contractAddress: "0x0b2c639c533813f4aa9d7837caf62653d097ff85",
      symbol: "USDC", name: "USD Coin", decimals: 6),
    mapping: CryptoProviderMapping(
      instrumentId: "10:0x0b2c639c533813f4aa9d7837caf62653d097ff85",
      coingeckoId: "usd-coin", cryptocompareSymbol: "USDC", binanceSymbol: "USDCUSDT"))

  /// A token with no provider mapping — stays chain-scoped; forms a
  /// singleton `assetKey` group so it is never aliased.
  static func noKeyToken(chainId: Int, address: String) -> CryptoRegistration {
    CryptoRegistration(
      instrument: .crypto(
        chainId: chainId, contractAddress: address,
        symbol: "UNK", name: "Unknown Token", decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "\(chainId):\(address.lowercased())",
        coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil))
  }
}

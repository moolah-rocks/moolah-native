// MoolahTests/App/UnifiedIdentityMigrationTestSupport.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Namespace marker (required by CODE_GUIDE §5 file_name rule).
enum UnifiedIdentityMigrationTestSupport {}

// MARK: - RePushRecorder

/// Spy actor that records profile IDs passed to the `rePush` closure.
actor RePushRecorder {
  private(set) var ids: [UUID] = []

  func record(_ id: UUID) {
    ids.append(id)
  }
}

// MARK: - MigrationTestHarness

/// In-memory harness for `UnifiedInstrumentIdentityMigration` tests.
@MainActor
struct MigrationTestHarness {
  let registry: GRDBInstrumentRegistryRepository
  /// Stub migration (no-op rePush, no cache) used by unit tests.
  let migration: UnifiedInstrumentIdentityMigration
  /// Per-profile in-memory databases shared between seeding and the migration.
  let cache: ProfileDatabaseCache
  /// Spy for asserting which profiles were re-pushed and in what order.
  let rePushRecorder: RePushRecorder
  /// Isolated UserDefaults suite so the completion flag does not leak between tests.
  let userDefaults: UserDefaults

  static func make() throws -> MigrationTestHarness {
    let database = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let suiteName = "test-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    let cache = ProfileDatabaseCache()
    let recorder = RePushRecorder()
    let stubMigration = UnifiedInstrumentIdentityMigration(
      profileIndexDatabase: database,
      dataDatabaseProvider: { _ in try ProfileDatabase.openInMemory() },
      allProfileIds: { [] },
      registry: registry,
      rePush: { _ in },
      userDefaults: defaults)
    return MigrationTestHarness(
      registry: registry,
      migration: stubMigration,
      cache: cache,
      rePushRecorder: recorder,
      userDefaults: defaults)
  }

  /// Seeds the shared registry with `registrations` via the normal `registerCrypto` path.
  func seedSharedRegistry(_ registrations: [CryptoRegistration]) async throws {
    for registration in registrations {
      try await registry.registerCrypto(registration.instrument, mapping: registration.mapping)
    }
  }
}

// MARK: - Per-profile database cache

/// Per-profile in-memory `DatabaseQueue` cache shared between seeding and the migration.
/// `@unchecked Sendable`: all test access is `@MainActor` (the harness and its
/// factories are `@MainActor`), so the unguarded `databases` dictionary is never
/// touched concurrently.
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

/// Returns a `MigrationTestHarness` backed by `cache` for per-profile-rewrite tests.
@MainActor
func makeProfileRewriteHarness() throws -> (
  harness: MigrationTestHarness, cache: ProfileDatabaseCache
) {
  let cache = ProfileDatabaseCache()
  let indexDatabase = try ProfileIndexDatabase.openInMemory()
  let registry = GRDBInstrumentRegistryRepository(database: indexDatabase)
  let suiteName = "test-profile-rewrite-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  let recorder = RePushRecorder()
  let stubMigration = UnifiedInstrumentIdentityMigration(
    profileIndexDatabase: indexDatabase,
    dataDatabaseProvider: { profileId in try cache.database(for: profileId) },
    allProfileIds: { [] },
    registry: registry,
    rePush: { _ in },
    userDefaults: defaults)
  let harness = MigrationTestHarness(
    registry: registry,
    migration: stubMigration,
    cache: cache,
    rePushRecorder: recorder,
    userDefaults: defaults)
  return (harness, cache)
}

// MARK: - Migration factory

extension MigrationTestHarness {
  /// Returns a migration wired to the shared index DB, per-profile cache, and
  /// `rePushRecorder`, with `allProfileIds` returning exactly `profileIds`.
  func migration(profileIds: [UUID]) -> UnifiedInstrumentIdentityMigration {
    let capturedCache = cache
    let capturedRecorder = rePushRecorder
    return UnifiedInstrumentIdentityMigration(
      profileIndexDatabase: migration.profileIndexDatabase,
      dataDatabaseProvider: { profileId in try capturedCache.database(for: profileId) },
      allProfileIds: { profileIds },
      registry: registry,
      rePush: { profileId in await capturedRecorder.record(profileId) },
      userDefaults: userDefaults)
  }
}

// MARK: - Profile seeding helpers

extension MigrationTestHarness {
  /// Seeds `profileId`'s database with one retired row in each FK table.
  func seedProfileWithRetiredLegs(_ profileId: UUID) async throws {
    let queue = try cache.database(for: profileId)
    try await queue.write { database in try seedRetiredRows(database) }
  }

  /// Seeds a rich profile: all FK tables with retired ids, a canonical `1:native`
  /// leg, and an OP→Coinstash transfer pair (one `10:native` + one `1:native`).
  /// After migration both transfer legs carry `1:native`, proving reconciliation.
  func seedFullProfile(_ profileId: UUID) async throws {
    let queue = try cache.database(for: profileId)
    try await queue.write { database in
      try seedRetiredRows(database)
      try seedCanonicalAndTransferPair(database)
    }
  }
}

/// Inserts a canonical `1:native` income leg and a transfer pair into `database`.
/// Extracted from `seedFullProfile` to stay under `closure_body_length`.
private func seedCanonicalAndTransferPair(_ database: Database) throws {
  // Canonical Coinstash income leg — already on 1:native (no rewrite needed).
  let canonicalLegId = UUID()
  try database.execute(
    sql:
      "INSERT INTO transaction_leg "
      + "(id, record_name, transaction_id, instrument_id, quantity, type, sort_order) "
      + "VALUES (?, ?, ?, '1:native', 50, 'income', 0)",
    arguments: [canonicalLegId, "TxLeg|\(canonicalLegId.uuidString)", UUID()])
  // Transfer pair: OP wallet (10:native) → Coinstash (1:native). Same transaction_id.
  // After migration both legs must carry '1:native' — the reconciliation proof.
  let transferTxId = UUID()
  let opLegId = UUID()
  let coinstashLegId = UUID()
  try database.execute(
    sql:
      "INSERT INTO transaction_leg "
      + "(id, record_name, transaction_id, instrument_id, quantity, type, sort_order) "
      + "VALUES (?, ?, ?, '10:native', 100, 'transfer', 0)",
    arguments: [opLegId, "TxLeg|\(opLegId.uuidString)", transferTxId])
  try database.execute(
    sql:
      "INSERT INTO transaction_leg "
      + "(id, record_name, transaction_id, instrument_id, quantity, type, sort_order) "
      + "VALUES (?, ?, ?, '1:native', 100, 'transfer', 1)",
    arguments: [coinstashLegId, "TxLeg|\(coinstashLegId.uuidString)", transferTxId])
}

// MARK: - Query helpers

extension MigrationTestHarness {
  /// Returns all `instrument_id` values from `table` in `profileId`'s database.
  /// `table` is validated against an allowlist (DATABASE_CODE_GUIDE §4).
  func allInstrumentIds(_ profileId: UUID, _ table: String) async throws -> [String] {
    let allowed: Set<String> = [
      "transaction_leg", "earmark", "earmark_budget_item",
      "account_group", "investment_value", "account",
    ]
    precondition(allowed.contains(table), "allInstrumentIds: unlisted table '\(table)'")
    let queue = try cache.database(for: profileId)
    return try await queue.read { database in
      try String.fetchAll(database, sql: "SELECT instrument_id FROM \(table)")
    }
  }

  /// Returns `true` when a row with `id` exists in `table` of the shared index DB.
  func rowExists(_ table: String, id: String) async throws -> Bool {
    let allowed: Set<String> = ["instrument"]
    precondition(allowed.contains(table), "rowExists: unlisted table '\(table)'")
    return try await migration.profileIndexDatabase.read { database in
      let count =
        try Int.fetchOne(
          database, sql: "SELECT count(*) FROM \(table) WHERE id = ?",
          arguments: [id]) ?? 0
      return count > 0
    }
  }

  /// Returns the single `instrument_id` shared by all `type = 'transfer'` legs in
  /// `profileId`'s database, or `nil` when transfer legs disagree (i.e. the
  /// OP→Coinstash transfer pair has not yet been reconciled to a single id).
  func transferLegsShareInstrument(_ profileId: UUID) async throws -> String? {
    let queue = try cache.database(for: profileId)
    return try await queue.read { database in
      let ids = try String.fetchAll(
        database,
        sql: "SELECT DISTINCT instrument_id FROM transaction_leg WHERE type = 'transfer'")
      return ids.count == 1 ? ids.first : nil
    }
  }

  /// Captures `instrument_id` values across all FK tables in `profileId`'s
  /// database. Used for idempotency checks: run the migration twice and assert
  /// the second snapshot equals the first. `earmark_savings_target` is stored
  /// separately (may be NULL, represented as an empty string).
  func snapshotAllTables(_ profileId: UUID) async throws -> [String: [String]] {
    let queue = try cache.database(for: profileId)
    return try await queue.read { try fetchTableSnapshot($0) }
  }
}

/// Reads `instrument_id` values from every FK table and returns a keyed
/// snapshot. Extracted from `snapshotAllTables` to stay under
/// `closure_body_length` (DATABASE_CODE_GUIDE §5 / SwiftLint limit).
/// Table names are hardcoded literals — not user input (DATABASE_CODE_GUIDE §4).
private func fetchTableSnapshot(_ database: Database) throws -> [String: [String]] {
  var snap: [String: [String]] = [:]
  let tables = [
    "transaction_leg", "earmark", "earmark_budget_item",
    "account_group", "investment_value", "account",
  ]
  for table in tables {
    // Allowlist guard consistent with the file-wide pattern (DATABASE_CODE_GUIDE §4),
    // even though `tables` is a closed literal set — protects a future caller.
    precondition(tables.contains(table), "fetchTableSnapshot: unlisted table '\(table)'")
    snap[table] = try String.fetchAll(
      database, sql: "SELECT instrument_id FROM \(table) ORDER BY rowid")
  }
  snap["earmark_savings_target"] = try Row.fetchAll(
    database, sql: "SELECT savings_target_instrument_id FROM earmark ORDER BY rowid"
  ).map { ($0[0] as String?) ?? "" }
  return snap
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

// MARK: - Free query utilities

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
      binanceSymbol: "ETHUSDT"))

  /// ETH on Optimism — retired cross-chain id (`10:native`).
  static let ethOptimism = CryptoRegistration(
    instrument: .crypto(
      chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
    mapping: CryptoProviderMapping(
      instrumentId: "10:native", coingeckoId: "ethereum",
      binanceSymbol: "ETHUSDT"))

  /// ETH on Base — retired cross-chain id (`8453:native`).
  static let ethBase = CryptoRegistration(
    instrument: .crypto(
      chainId: 8453, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
    mapping: CryptoProviderMapping(
      instrumentId: "8453:native", coingeckoId: "ethereum",
      binanceSymbol: "ETHUSDT"))

  /// USDC on Ethereum mainnet — canonical.
  static let usdcMainnet = CryptoRegistration(
    instrument: .crypto(
      chainId: 1,
      contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      symbol: "USDC", name: "USD Coin", decimals: 6),
    mapping: CryptoProviderMapping(
      instrumentId: "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      coingeckoId: "usd-coin", binanceSymbol: "USDCUSDT"))

  /// USDC on Optimism — retired cross-chain id.
  static let usdcOptimism = CryptoRegistration(
    instrument: .crypto(
      chainId: 10,
      contractAddress: "0x0b2c639c533813f4aa9d7837caf62653d097ff85",
      symbol: "USDC", name: "USD Coin", decimals: 6),
    mapping: CryptoProviderMapping(
      instrumentId: "10:0x0b2c639c533813f4aa9d7837caf62653d097ff85",
      coingeckoId: "usd-coin", binanceSymbol: "USDCUSDT"))

  /// A token with no provider mapping — stays chain-scoped; forms a
  /// singleton `assetKey` group so it is never aliased.
  static func noKeyToken(chainId: Int, address: String) -> CryptoRegistration {
    CryptoRegistration(
      instrument: .crypto(
        chainId: chainId, contractAddress: address,
        symbol: "UNK", name: "Unknown Token", decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "\(chainId):\(address.lowercased())",
        coingeckoId: nil, binanceSymbol: nil))
  }
}

// MARK: - Test-only migration helpers

extension UnifiedInstrumentIdentityMigration {
  /// Sets the completion flag. Unit-test only — lets a test confirm that a
  /// gated surface (e.g. `ReportingStore.isMigratingCrossChainIdentity`)
  /// observes the flag without running the full migration.
  /// No production code path should invoke this.
  nonisolated static func markCompleteForTesting(in defaults: UserDefaults) {
    defaults.set(true, forKey: gateKey)
  }
}

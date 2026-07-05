@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Rollback contract test for the multi-statement write on
/// `GRDBInstrumentRegistryRepository.applyRemoteChangesSync`. Mirrors
/// `ProfileIndexRollbackTests` / `CSVImportRollbackTests` — per
/// `guides/DATABASE_CODE_GUIDE.md` §5 every multi-statement write must
/// roll back atomically when any statement throws, so prior on-disk
/// state survives byte-equal and no partial write lands.
///
/// `applyRemoteChangesSync` upserts every saved row and then deletes
/// every id inside a single `database.write` closure. A `BEFORE INSERT`
/// trigger that aborts on a sentinel `id` forces the second saved row's
/// INSERT to throw *inside* that transaction, so the first row's upsert
/// (which already mutated a pre-seeded row via the UPDATE side of the
/// conflict resolution) must roll back with it.
@Suite("Shared instrument-registry GRDB rollback contracts")
struct GRDBInstrumentRegistryRollbackTests {

  @Test
  func applyRemoteChangesSyncRollsBackOnFailure() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: database)

    // Seed an initial stored row whose ticker we'll attempt (and fail)
    // to mutate via the failing batch.
    let priorId = "1:0xabc"
    let prior = InstrumentRow(
      domain: Instrument.crypto(
        chainId: 1, contractAddress: "0xabc", symbol: "PRE", name: "Prior",
        decimals: 18))
    try await database.write { database in
      try prior.insert(database)
    }

    // Trigger that aborts any INSERT whose id matches the sentinel. The
    // first batch row upserts successfully (its id already exists, so
    // SQLite resolves the conflict via UPDATE); the second row's INSERT
    // trips the trigger inside `applyRemoteChangesSync`'s single
    // transaction, so every statement — including the upsert that
    // already touched `priorId` — must roll back.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_instrument_upsert
          BEFORE INSERT ON instrument
          WHEN NEW.id = '___FAIL___'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    // Saved batch: a row that mutates the prior row's name (UPDATE side
    // of upsert) followed by a brand-new row that trips the trigger on
    // INSERT.
    var mutating = InstrumentRow(
      domain: Instrument.crypto(
        chainId: 1, contractAddress: "0xabc", symbol: "MUT",
        name: "MUTATED NAME THAT MUST NOT LAND", decimals: 18))
    mutating.recordName = prior.recordName
    var failing = InstrumentRow(
      domain: Instrument.crypto(
        chainId: 9, contractAddress: nil, symbol: "FAIL", name: "Fail",
        decimals: 18))
    failing.id = "___FAIL___"
    failing.recordName = "___FAIL___"

    do {
      try registry.applyRemoteChangesSync(saved: [mutating, failing], deleted: [])
      Issue.record("applyRemoteChangesSync should have thrown but did not")
    } catch {
      // Expected — trigger raises ABORT mid-transaction.
    }

    // The prior row's name survives byte-equal: the mutating upsert
    // never committed.
    let surviving = try #require(try registry.fetchRowSync(id: priorId))
    #expect(surviving.name == "Prior")
    // And the failing row was NOT persisted — no partial write.
    #expect(try registry.fetchRowSync(id: "___FAIL___") == nil)
    #expect(try registry.allRowIdsSync() == [priorId])
  }

  /// `registerCrypto(_:mapping:forcingStatus:)` does a fetch + UPDATE (or
  /// INSERT) inside one `database.write`. A `BEFORE UPDATE` trigger that
  /// aborts the existing-row UPDATE forces the throw mid-transaction, so
  /// the pre-seeded status and mapping must survive byte-equal. The
  /// post-write side effects (`fireOnRecordChanged` / `notifySubscribers`)
  /// cannot run because `try await database.write` rethrows first — that
  /// is what keeps a failed write from queuing a CKSyncEngine save.
  @Test
  func registerCryptoForcingStatusRollsBackOnFailure() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18)
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum",
        binanceSymbol: nil),
      forcingStatus: .spam)

    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_instrument_update
          BEFORE UPDATE ON instrument
          WHEN NEW.id = '\(eth.id)'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    do {
      try await registry.registerCrypto(
        eth,
        mapping: CryptoProviderMapping(
          instrumentId: eth.id, coingeckoId: "MUST-NOT-LAND",
          binanceSymbol: nil),
        forcingStatus: .priced)
      Issue.record("registerCrypto(forcingStatus:) should have thrown")
    } catch {
      // Expected — trigger raises ABORT mid-transaction.
    }

    let surviving = try #require(try registry.fetchRowSync(id: eth.id))
    #expect(surviving.pricingStatus == TokenPricingStatus.spam.rawValue)
    #expect(surviving.coingeckoId == "ethereum")
  }

  /// Same rollback contract for the plain `registerCrypto(_:mapping:)`
  /// overload — it shares the same fetch + UPDATE upsert path, so a
  /// failed write must leave the prior status and mapping unchanged.
  @Test
  func registerCryptoPlainRollsBackOnFailure() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18)
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum",
        binanceSymbol: nil),
      forcingStatus: .spam)

    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_instrument_update
          BEFORE UPDATE ON instrument
          WHEN NEW.id = '\(eth.id)'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    do {
      try await registry.registerCrypto(
        eth,
        mapping: CryptoProviderMapping(
          instrumentId: eth.id, coingeckoId: "MUST-NOT-LAND",
          binanceSymbol: nil))
      Issue.record("registerCrypto(_:mapping:) should have thrown")
    } catch {
      // Expected — trigger raises ABORT mid-transaction.
    }

    let surviving = try #require(try registry.fetchRowSync(id: eth.id))
    #expect(surviving.pricingStatus == TokenPricingStatus.spam.rawValue)
    #expect(surviving.coingeckoId == "ethereum")
  }

  /// Rollback contract for the `setAliasOf` write inside `applyRemoteChangesSync`.
  /// The existing rollback tests construct the registry without a `canonicalResolver`,
  /// so the `setAliasOf` code path is never exercised in a rollback scenario. This
  /// test constructs the registry WITH a real `CanonicalInstrumentResolver` (its
  /// static map maps `10:native` → `1:native`), applies a stale echo of the retired
  /// `10:native` row (which triggers the alias write on the stale-echo branch) followed
  /// by a sentinel row that trips a `BEFORE INSERT` trigger, and asserts that the
  /// `setAliasOf` write rolled back with the rest of the transaction — `alias_of`
  /// stays `NULL` on the pre-seeded retired row.
  @Test
  func applyRemoteChangesSyncAliasWriteRollsBackOnFailure() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(
      database: database, canonicalResolver: CanonicalInstrumentResolver())
    let zone = CKRecordZone.ID(zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
    let tOlder = Date(timeIntervalSince1970: 1_700_000_000)
    let tNewer = Date(timeIntervalSince1970: 1_700_000_060)

    // Pre-seed the retired `10:native` row stamped at tNewer with alias_of = NULL
    // (simulating a row that arrived before the alias feature shipped).
    let retiredInstrument = Instrument.crypto(
      chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    var prior = InstrumentRow(domain: retiredInstrument)
    prior.encodedSystemFields =
      prior.toCKRecord(in: zone).withModificationDate(tNewer).encodedSystemFields
    let priorRow = prior
    try await database.write { database in try priorRow.insert(database) }

    // Trigger that aborts any INSERT whose id matches the sentinel.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_instrument_upsert
          BEFORE INSERT ON instrument
          WHEN NEW.id = '___FAIL___'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    // Stale echo (older date → stale-echo branch fires `setAliasOf` to write
    // alias_of = "1:native") followed by a sentinel that trips the trigger,
    // aborting the whole transaction before the alias write commits.
    var staleEcho = InstrumentRow(domain: retiredInstrument)
    staleEcho.encodedSystemFields =
      staleEcho.toCKRecord(in: zone).withModificationDate(tOlder).encodedSystemFields
    var failing = InstrumentRow(
      domain: Instrument.crypto(
        chainId: 9, contractAddress: nil, symbol: "FAIL", name: "Fail", decimals: 18))
    failing.id = "___FAIL___"
    failing.recordName = "___FAIL___"

    do {
      try registry.applyRemoteChangesSync(saved: [staleEcho, failing], deleted: [])
      Issue.record("applyRemoteChangesSync should have thrown but did not")
    } catch {
      // Expected — trigger raises ABORT mid-transaction.
    }

    // The `setAliasOf` call in the stale-echo branch rolled back:
    // `alias_of` remains NULL on the pre-seeded retired row.
    let aliasValue = try await registry.database.read { database in
      try String.fetchOne(
        database,
        sql: "SELECT alias_of FROM instrument WHERE id = ?",
        arguments: [retiredInstrument.id])
    }
    #expect(aliasValue == nil)
    // Pre-seeded row survives byte-equal and the sentinel was not persisted.
    let surviving = try #require(try registry.fetchRowSync(id: retiredInstrument.id))
    #expect(surviving.name == "Ethereum")
    #expect(try registry.fetchRowSync(id: "___FAIL___") == nil)
  }

  /// Rollback contract for the issue-#1085 stale-echo branch of
  /// `applyRemoteChangesSync`. When a stale echo (older `modificationDate`)
  /// carries a `pricingStatus` that the merge resolves to a *different*
  /// value, the gate writes ONLY `pricing_status` via a partial `updateAll`
  /// (identity/mapping fields are date-gated out). If a later row in the
  /// same batch throws, that partial write must roll back with the rest of
  /// the transaction. Seeds a `.priced` row cached at the NEWER date so the
  /// incoming older `.spam` echo takes the stale branch and fires the
  /// `updateAll`, then trips a `BEFORE INSERT` trigger on a sentinel id.
  @Test
  func applyRemoteChangesSyncStaleEchoUpdateRollsBackOnFailure() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let zone = CKRecordZone.ID(zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
    let tOlder = Date(timeIntervalSince1970: 1_700_000_000)
    let tNewer = Date(timeIntervalSince1970: 1_700_000_060)

    let priorId = "1:0xabc"
    let priorInstrument = Instrument.crypto(
      chainId: 1, contractAddress: "0xabc", symbol: "PRE", name: "Prior", decimals: 18)
    var prior = InstrumentRow(domain: priorInstrument)
    prior.pricingStatus = TokenPricingStatus.priced.rawValue
    prior.encodedSystemFields =
      prior.toCKRecord(in: zone).withModificationDate(tNewer).encodedSystemFields
    let priorRow = prior
    try await database.write { database in try priorRow.insert(database) }

    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_instrument_upsert
          BEFORE INSERT ON instrument
          WHEN NEW.id = '___FAIL___'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    // Stale echo (older date) carrying .spam → merge(.priced, .spam) = .spam,
    // which differs from the stored .priced, so the stale branch fires the
    // partial `updateAll(pricing_status = .spam)`.
    var staleEcho = InstrumentRow(domain: priorInstrument)
    staleEcho.pricingStatus = TokenPricingStatus.spam.rawValue
    staleEcho.encodedSystemFields =
      staleEcho.toCKRecord(in: zone).withModificationDate(tOlder).encodedSystemFields
    var failing = InstrumentRow(
      domain: Instrument.crypto(
        chainId: 9, contractAddress: nil, symbol: "FAIL", name: "Fail", decimals: 18))
    failing.id = "___FAIL___"
    failing.recordName = "___FAIL___"

    do {
      try registry.applyRemoteChangesSync(saved: [staleEcho, failing], deleted: [])
      Issue.record("applyRemoteChangesSync should have thrown but did not")
    } catch {
      // Expected — trigger raises ABORT mid-transaction.
    }

    // The partial pricing_status updateAll rolled back: status stays .priced.
    let surviving = try #require(try registry.fetchRowSync(id: priorId))
    #expect(surviving.pricingStatus == TokenPricingStatus.priced.rawValue)
    #expect(try registry.fetchRowSync(id: "___FAIL___") == nil)
    #expect(try registry.allRowIdsSync() == [priorId])
  }
}

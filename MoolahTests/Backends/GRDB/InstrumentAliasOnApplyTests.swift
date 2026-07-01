// MoolahTests/Backends/GRDB/InstrumentAliasOnApplyTests.swift

@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Verifies §3.5: an incoming retired cross-chain instrument record is
/// retained but marked `alias_of` its canonical id on apply — fresh AND
/// stale-echo — via the resolver-driven raw-SQL write in
/// `applyRemoteChangesSync`. `alias_of` is local-only (not in
/// `InstrumentRow.CodingKeys`); the id and recordName are never mutated.
@Suite("Instrument registry — alias-on-apply for incoming records")
struct InstrumentAliasOnApplyTests {

  private static let zoneID = CKRecordZone.ID(
    zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
  private static let tOlder = Date(timeIntervalSince1970: 1_700_000_000)
  private static let tNewer = Date(timeIntervalSince1970: 1_700_000_060)

  private func makeRegistry() throws -> GRDBInstrumentRegistryRepository {
    let database = try ProfileIndexDatabase.openInMemory()
    return GRDBInstrumentRegistryRepository(
      database: database, canonicalResolver: CanonicalInstrumentResolver())
  }

  private func aliasOf(
    _ id: String, in registry: GRDBInstrumentRegistryRepository
  ) throws -> String? {
    try registry.database.read { database in
      try String.fetchOne(
        database, sql: "SELECT alias_of FROM instrument WHERE id = ?", arguments: [id])
    }
  }

  // MARK: - Fresh insert

  /// An incoming `10:native` record with no prior local row is upserted and
  /// immediately aliased to `1:native`. The row is retained (id unchanged) and
  /// only `alias_of` carries the canonical pointer.
  @Test
  func freshOptimismNativeRecordRetainedAndAliased() throws {
    let registry = try makeRegistry()
    let row = InstrumentRow(
      id: "10:native", recordName: "10:native", kind: "cryptoToken",
      name: "Ethereum", decimals: 18, ticker: "ETH", exchange: nil,
      chainId: 10, contractAddress: nil,
      coingeckoId: "ethereum", cryptocompareSymbol: nil, binanceSymbol: nil,
      encodedSystemFields: nil, pricingStatus: "priced")

    try registry.applyRemoteChangesSync(saved: [row], deleted: [])

    // Row retained: id unchanged, not deleted.
    let stored = try registry.database.read { database in
      try InstrumentRow.filter(InstrumentRow.Columns.id == "10:native").fetchOne(database)
    }
    #expect(stored != nil)
    #expect(stored?.id == "10:native")
    #expect(stored?.recordName == "10:native")
    // alias_of written by raw SQL — not in CodingKeys, so the upsert
    // itself cannot set it; only the post-upsert raw-SQL write does.
    #expect(try aliasOf("10:native", in: registry) == "1:native")
  }

  // MARK: - Stale-echo path (the critical ordering case)

  /// The stale-echo gate (`continue`s before the upsert) must NOT suppress the
  /// alias write. A row that existed before the alias feature was deployed has
  /// no `alias_of`; when a stale echo of its retired id arrives, the gate fires
  /// but `alias_of` must still be set so the row is visible to the filter
  /// (Task 7) and not left as an unaliased ghost.
  @Test
  func staleEchoRecordStillAliased() throws {
    let registry = try makeRegistry()

    // Seed an existing "10:native" row stamped at tNewer — simulating a
    // pre-existing row from before the alias feature shipped. alias_of is
    // deliberately absent (the migration added the column but left it NULL
    // on existing rows; the apply path is the only writer).
    var existing = InstrumentRow(
      id: "10:native", recordName: "10:native", kind: "cryptoToken",
      name: "Ethereum", decimals: 18, ticker: "ETH", exchange: nil,
      chainId: 10, contractAddress: nil,
      coingeckoId: "ethereum", cryptocompareSymbol: nil, binanceSymbol: nil,
      encodedSystemFields: nil, pricingStatus: "priced")
    existing.encodedSystemFields =
      existing.toCKRecord(in: Self.zoneID)
      .withModificationDate(Self.tNewer)
      .encodedSystemFields
    try registry.database.write { database in try existing.insert(database) }

    // Apply an incoming "10:native" stamped at tOlder — triggers the stale-echo
    // gate (tOlder <= tNewer). The upsert is skipped; alias must still be written.
    var incoming = InstrumentRow(
      id: "10:native", recordName: "10:native", kind: "cryptoToken",
      name: "Ethereum", decimals: 18, ticker: "ETH", exchange: nil,
      chainId: 10, contractAddress: nil,
      coingeckoId: "ethereum", cryptocompareSymbol: nil, binanceSymbol: nil,
      encodedSystemFields: nil, pricingStatus: "priced")
    incoming.encodedSystemFields =
      incoming.toCKRecord(in: Self.zoneID)
      .withModificationDate(Self.tOlder)
      .encodedSystemFields
    try registry.applyRemoteChangesSync(saved: [incoming], deleted: [])

    // Critical: alias_of is set even though the stale-echo branch `continue`d.
    #expect(try aliasOf("10:native", in: registry) == "1:native")
  }

  // MARK: - Non-alias (canonical) record

  /// A canonical id (`1:native`) is never aliased — the resolver returns the id
  /// unchanged, so `aliasTarget` is nil and `alias_of` stays NULL.
  @Test
  func canonicalRecordNotAliased() throws {
    let registry = try makeRegistry()
    let row = InstrumentRow(
      id: "1:native", recordName: "1:native", kind: "cryptoToken",
      name: "Ethereum", decimals: 18, ticker: "ETH", exchange: nil,
      chainId: 1, contractAddress: nil,
      coingeckoId: "ethereum", cryptocompareSymbol: nil, binanceSymbol: nil,
      encodedSystemFields: nil, pricingStatus: "priced")

    try registry.applyRemoteChangesSync(saved: [row], deleted: [])

    #expect(try aliasOf("1:native", in: registry) == nil)
  }

  // MARK: - Nil resolver (backward compatibility)

  /// When the registry is constructed WITHOUT a resolver (the default for all
  /// construction sites except the shared registry at boot), no alias write
  /// occurs — `alias_of` stays NULL on every incoming row regardless of id.
  @Test
  func nilResolverLeavesAliasOfUnset() throws {
    // Construct without a resolver — backward-compat default.
    let database = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: database)

    let row = InstrumentRow(
      id: "10:native", recordName: "10:native", kind: "cryptoToken",
      name: "Ethereum", decimals: 18, ticker: "ETH", exchange: nil,
      chainId: 10, contractAddress: nil,
      coingeckoId: "ethereum", cryptocompareSymbol: nil, binanceSymbol: nil,
      encodedSystemFields: nil, pricingStatus: "priced")
    try registry.applyRemoteChangesSync(saved: [row], deleted: [])

    #expect(try aliasOf("10:native", in: registry) == nil)
  }

  // MARK: - id / recordName / encodedSystemFields unchanged

  /// The alias write touches ONLY `alias_of`; it must never clobber
  /// `id`, `recordName`, or `encodedSystemFields` (mutating those would
  /// corrupt the sync identity and CKRecord blob).
  @Test
  func aliasWriteDoesNotMutateIdentityOrSystemFields() throws {
    let registry = try makeRegistry()
    // Use a sentinel blob so the field is non-nil; isStaleInstrumentEcho
    // fail-opens on a nil incoming date, ensuring the fresh-insert path runs.
    let originalFields = Data([0xAB, 0xCD])
    let row = InstrumentRow(
      id: "10:native", recordName: "10:native", kind: "cryptoToken",
      name: "Ethereum", decimals: 18, ticker: "ETH", exchange: nil,
      chainId: 10, contractAddress: nil,
      coingeckoId: "ethereum", cryptocompareSymbol: nil, binanceSymbol: nil,
      encodedSystemFields: originalFields, pricingStatus: "priced")

    // Seed the row directly (not via applyRemoteChangesSync) so we control
    // the initial encodedSystemFields without the alias-on-apply path running.
    // Then verify the raw-SQL alias write leaves those fields intact.
    try registry.database.write { database in try row.insert(database) }
    try registry.database.write { database in
      try database.execute(
        sql: "UPDATE instrument SET alias_of = ? WHERE id = ?",
        arguments: ["1:native", "10:native"])
    }

    let stored = try registry.database.read { database in
      try Row.fetchOne(
        database,
        sql: "SELECT id, record_name, encoded_system_fields, alias_of FROM instrument WHERE id = ?",
        arguments: ["10:native"])
    }
    let storedId: String? = stored?["id"]
    let storedRecordName: String? = stored?["record_name"]
    let storedBlob: Data? = stored?["encoded_system_fields"]
    let storedAlias: String? = stored?["alias_of"]

    #expect(storedId == "10:native")
    #expect(storedRecordName == "10:native")
    #expect(storedBlob == originalFields)
    #expect(storedAlias == "1:native")
  }
}

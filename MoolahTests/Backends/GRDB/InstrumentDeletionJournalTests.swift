import Foundation
import GRDB
import Testing

@testable import Moolah

/// Durable deletion-journal wiring for the shared instrument registry
/// (issue #1097). Instruments live in the profile-index DB and sync in the
/// `profile-index` zone (like `ProfileRow`, NOT the per-profile `@profile-data`
/// sentinel). A hard delete must record a durable intent in the SAME
/// transaction as the row delete so an engine-down window / state reset can't
/// lose it (and a token-less refetch can't resurrect the instrument); a
/// (re-)register clears that intent (D1-b); a fiat remove is a no-op and never
/// journals.
@Suite("Instrument deletion journal (#1097)")
struct InstrumentDeletionJournalTests {

  private func makeDatabase() throws -> DatabaseQueue {
    try ProfileIndexDatabase.openInMemory()
  }

  private func entries(_ database: DatabaseQueue) async throws -> [DeletionJournalRow] {
    try await database.read { try DeletionJournal.allEntries(in: $0) }
  }

  // MARK: - Delete journals an index-zone intent

  @Test("removing a crypto instrument journals an index-zone deletion atomically")
  func cryptoRemoveJournalsIndexZoneDeletion() async throws {
    let database = try makeDatabase()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum",
        cryptocompareSymbol: nil, binanceSymbol: nil))
    #expect(try await entries(database).isEmpty)

    try await registry.remove(id: eth.id)

    let afterDelete = try await entries(database)
    #expect(afterDelete.count == 1)
    let entry = try #require(afterDelete.first)
    #expect(entry.zoneName == DeletionJournal.profileIndexZoneName)
    #expect(entry.recordName == InstrumentRow.recordName(for: eth.id))
    #expect(entry.recordName == eth.id)  // bare id, no recordType| prefix
    #expect(entry.recordType == InstrumentRow.recordType)
  }

  @Test("removing a stock instrument journals an index-zone deletion")
  func stockRemoveJournalsIndexZoneDeletion() async throws {
    let database = try makeDatabase()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    try await registry.registerStock(bhp)

    try await registry.remove(id: bhp.id)

    let entry = try #require(try await entries(database).first)
    #expect(entry.zoneName == DeletionJournal.profileIndexZoneName)
    #expect(entry.recordName == bhp.id)
    #expect(entry.recordType == InstrumentRow.recordType)
  }

  // MARK: - Clear-on-recreate (D1-b)

  @Test("delete-then-re-register a crypto id nets zero tombstone")
  func cryptoRecreateClearsTombstone() async throws {
    let database = try makeDatabase()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let mapping = CryptoProviderMapping(
      instrumentId: eth.id, coingeckoId: "ethereum",
      cryptocompareSymbol: nil, binanceSymbol: nil)
    try await registry.registerCrypto(eth, mapping: mapping)
    try await registry.remove(id: eth.id)
    #expect(try await entries(database).count == 1)

    // Re-register the SAME id (undo / re-discovery) → the register write drops
    // the stale intent in the same transaction.
    try await registry.registerCrypto(eth, mapping: mapping)
    #expect(try await entries(database).isEmpty)
  }

  @Test("delete-then-re-register a stock id nets zero tombstone")
  func stockRecreateClearsTombstone() async throws {
    let database = try makeDatabase()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    try await registry.registerStock(bhp)
    try await registry.remove(id: bhp.id)
    #expect(try await entries(database).count == 1)

    try await registry.registerStock(bhp)
    #expect(try await entries(database).isEmpty)
  }

  @Test("the forcing-status crypto overload also clears a stale tombstone")
  func cryptoForcingStatusRecreateClearsTombstone() async throws {
    let database = try makeDatabase()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let mapping = CryptoProviderMapping(
      instrumentId: eth.id, coingeckoId: "ethereum",
      cryptocompareSymbol: nil, binanceSymbol: nil)
    try await registry.registerCrypto(eth, mapping: mapping)
    try await registry.remove(id: eth.id)
    #expect(try await entries(database).count == 1)

    try await registry.registerCrypto(eth, mapping: mapping, forcingStatus: .spam)
    #expect(try await entries(database).isEmpty)
  }

  // MARK: - Apply-path (peer save clears a stale intent)

  @Test("a peer save of the same id clears our stale instrument intent (D1-b)")
  func applyPathSaveClearsStaleIntent() async throws {
    let database = try makeDatabase()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum",
        cryptocompareSymbol: nil, binanceSymbol: nil))
    try await registry.remove(id: eth.id)
    #expect(try await entries(database).count == 1)

    let row = InstrumentRow(domain: eth)
    try registry.applyRemoteChangesSync(saved: [row], deleted: [])
    #expect(try await entries(database).isEmpty)
  }

  @Test("a server-originated apply-path delete does not journal")
  func applyPathDeleteNeverJournals() async throws {
    let database = try makeDatabase()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum",
        cryptocompareSymbol: nil, binanceSymbol: nil))

    try registry.applyRemoteChangesSync(saved: [], deleted: [eth.id])
    #expect(try await entries(database).isEmpty)
  }

  // MARK: - Fiat is never hard-deleted → never journaled

  @Test("removing a fiat id is a no-op and never journals")
  func fiatRemoveNeverJournals() async throws {
    let database = try makeDatabase()
    let registry = GRDBInstrumentRegistryRepository(database: database)

    try await registry.remove(id: "AUD")  // ambient fiat — no stored row
    #expect(try await entries(database).isEmpty)

    try await registry.remove(id: "DOES_NOT_EXIST:FOO")  // unknown id
    #expect(try await entries(database).isEmpty)
  }

  // MARK: - Rollback: a failed journal write rolls back the row delete

  @Test("a forced journal-insert failure rolls back the instrument delete atomically")
  func journalWriteFailureRollsBackDelete() async throws {
    let database = try makeDatabase()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    try await registry.registerStock(bhp)

    // Abort any INSERT into the journal mid-transaction, so the row delete that
    // precedes it in the same `database.write` must roll back with it — the row
    // survives, the deletion is not lost half-way. A universal (no-`WHEN`)
    // trigger suffices: `remove(id:)` is the only journal INSERT in this
    // in-memory DB, and it avoids interpolating a value into a `sql:` argument
    // (DATABASE_CODE_GUIDE §4).
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_instrument_journal
          BEFORE INSERT ON deletion_journal
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    await #expect(throws: (any Error).self) {
      try await registry.remove(id: bhp.id)
    }

    // The instrument row survived byte-equal (delete rolled back) and no journal
    // row landed — no partial write.
    #expect(try await entries(database).isEmpty)
    #expect(try registry.fetchRowSync(id: bhp.id) != nil)
  }
}

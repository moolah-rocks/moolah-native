import Foundation
import GRDB
import Testing
import os

@testable import Moolah

/// Counts committed write transactions on a `DatabaseQueue` so a test can
/// assert that a batch collapses N row writes into one transaction (issue
/// #1197). `observes` returns false — we only care about the commit
/// callback, which GRDB fires for every committed transaction regardless of
/// the observed-events filter.
private final class CommitCounter: @unchecked Sendable {
  private let counter = OSAllocatedUnfairLock(initialState: 0)

  var commitCount: Int { counter.withLock { $0 } }

  func recordCommit() { counter.withLock { $0 += 1 } }
}

extension CommitCounter: TransactionObserver {
  func observes(eventsOfKind eventKind: DatabaseEventKind) -> Bool { false }
  func databaseDidChange(with event: DatabaseEvent) {}
  func databaseDidCommit(_ database: Database) { recordCommit() }
  func databaseDidRollback(_ database: Database) {}
}

@Suite("GRDBInstrumentRegistryRepository registerCryptoBatch")
struct GRDBInstrumentRegistryBatchTests {
  private func makeRegistry() throws -> GRDBInstrumentRegistryRepository {
    let queue = try ProfileIndexDatabase.openInMemory()
    return GRDBInstrumentRegistryRepository(database: queue)
  }

  private func pairs(
    _ registrations: [CryptoRegistration]
  ) -> [(instrument: Instrument, mapping: CryptoProviderMapping)] {
    registrations.map { (instrument: $0.instrument, mapping: $0.mapping) }
  }

  @Test("Seeds every provided registration")
  func registersAll() async throws {
    let registry = try makeRegistry()
    let presets = CryptoRegistration.builtInPresets
    try await registry.registerCryptoBatch(pairs(presets))

    let stored = try await registry.allCryptoRegistrations()
    for preset in presets {
      #expect(
        stored.contains { $0.id == preset.id },
        "\(preset.id) not seeded by registerCryptoBatch")
    }
  }

  @Test("Collapses all row writes into a single transaction")
  func usesSingleTransaction() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let counter = CommitCounter()
    queue.add(transactionObserver: counter)
    let registry = GRDBInstrumentRegistryRepository(database: queue)

    let presets = CryptoRegistration.builtInPresets
    try #require(presets.count > 1)
    try await registry.registerCryptoBatch(pairs(presets))

    #expect(counter.commitCount == 1)
  }

  @Test("Fires onRecordChanged exactly once per registration")
  func onRecordChangedFiresOncePerRegistration() async throws {
    let changed = OSAllocatedUnfairLock(initialState: [String]())
    let queue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(
      database: queue,
      onRecordChanged: { id in changed.withLock { $0.append(id) } })

    let presets = Array(CryptoRegistration.builtInPresets.prefix(3))
    try await registry.registerCryptoBatch(pairs(presets))

    let fired = changed.withLock { $0 }
    #expect(fired.count == presets.count)
    #expect(Set(fired) == Set(presets.map(\.instrument.id)))
  }

  @Test("Empty input is a no-op with no transaction")
  func emptyInputNoOp() async throws {
    let queue = try ProfileIndexDatabase.openInMemory()
    let counter = CommitCounter()
    queue.add(transactionObserver: counter)
    let registry = GRDBInstrumentRegistryRepository(database: queue)

    try await registry.registerCryptoBatch([])

    #expect(counter.commitCount == 0)
    #expect(try await registry.allCryptoRegistrations().isEmpty)
  }

  @Test("A nil incoming mapping column does not clobber a resolved one")
  func upgradeOnlyMergePreserved() async throws {
    let registry = try makeRegistry()
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum", cryptocompareSymbol: "ETH",
        binanceSymbol: "ETHUSDT"))

    // A thin all-nil re-register via the batch path must merge, not blank.
    try await registry.registerCryptoBatch([
      (
        instrument: eth,
        mapping: CryptoProviderMapping(
          instrumentId: eth.id, coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil)
      )
    ])

    let reg = try await registry.cryptoRegistration(byId: eth.id)
    #expect(reg?.mapping.coingeckoId == "ethereum")
    #expect(reg?.mapping.cryptocompareSymbol == "ETH")
    #expect(reg?.mapping.binanceSymbol == "ETHUSDT")
  }

  /// The batch runs all N `upsertCrypto` calls inside one `database.write`,
  /// so a throw on any element must roll the whole transaction back (per
  /// `guides/DATABASE_CODE_GUIDE.md` §5). A `BEFORE INSERT` trigger aborts
  /// the second element's INSERT mid-batch; the first element's UPDATE of a
  /// pre-seeded row must roll back with it, and the post-write fan-out must
  /// not run. Uses a hardcoded sentinel id (`9:native`) in the trigger — no
  /// `sql:` string interpolation.
  @Test("A throw mid-batch rolls the whole write back")
  func rollsBackOnMidBatchFailure() async throws {
    let registry = try makeRegistry()
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum", cryptocompareSymbol: nil,
        binanceSymbol: nil))

    // Aborts the fresh `9:native` INSERT the second batch element performs.
    try await registry.database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_instrument_batch_insert
          BEFORE INSERT ON instrument
          WHEN NEW.id = '9:native'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    let failing = Instrument.crypto(
      chainId: 9, contractAddress: nil, symbol: "FAIL", name: "Fail", decimals: 18)
    try #require(failing.id == "9:native")

    await #expect(throws: (any Error).self) {
      // First element UPDATEs the pre-seeded eth row (would overwrite its
      // coingeckoId); second element trips the trigger on INSERT.
      try await registry.registerCryptoBatch([
        (
          instrument: eth,
          mapping: CryptoProviderMapping(
            instrumentId: eth.id, coingeckoId: "MUST-NOT-LAND",
            cryptocompareSymbol: nil, binanceSymbol: nil)
        ),
        (
          instrument: failing,
          mapping: CryptoProviderMapping(
            instrumentId: failing.id, coingeckoId: "fail", cryptocompareSymbol: nil,
            binanceSymbol: nil)
        ),
      ])
    }

    // The eth UPDATE rolled back: coingeckoId survives byte-equal.
    let surviving = try #require(try await registry.cryptoRegistration(byId: eth.id))
    #expect(surviving.mapping.coingeckoId == "ethereum")
    // The failing row never landed — no partial write.
    #expect(try await registry.cryptoRegistration(byId: "9:native") == nil)
  }
}

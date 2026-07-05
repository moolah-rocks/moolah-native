// MoolahTests/Backends/GRDB/EmkRepoSharedInstrumentResolutionTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the architectural contract that `GRDBEarmarkRepository` resolves
/// position instruments via the injected `InstrumentMapResolving` (the
/// shared profile-index registry), not via a read of the per-profile
/// `instrument` table inside its own `fetchAll` / `observeAll` snapshot.
///
/// The proof is constructed so per-profile resolution *cannot* succeed:
/// the earmark, transaction, and leg rows are inserted directly into the
/// per-profile database (raw row inserts, so no placeholder `instrument`
/// row is planted). The per-profile `instrument` table therefore has
/// **no** row for the crypto instrument; it exists only in the shared
/// registry. If the read still resolves the position to the full crypto
/// `Instrument` (kind `.cryptoToken`) rather than the
/// `Instrument.fiat(code:)` fallback `computeEarmarkPositions` applies on
/// a miss, resolution provably came from the injected resolver.
@Suite("Earmark reads resolve instruments from the shared registry")
struct EmkRepoSharedInstrumentResolutionTests {
  /// Bundle returned by `makeSeededRepo`.
  private struct SeededRepo {
    let repo: GRDBEarmarkRepository
    let earmarkId: UUID
    let eth: Instrument
  }

  private func makeSeededRepo() async throws -> SeededRepo {
    let perProfile = try ProfileDatabase.openInMemory()
    let sharedQueue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: sharedQueue)
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18)
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum",
        binanceSymbol: "ETHUSDT"))

    let repo = GRDBEarmarkRepository(
      database: perProfile,
      defaultInstrument: Instrument.fiat(code: "USD"),
      instrumentResolver: registry)

    let earmark = Earmark(name: "Crypto savings", instrument: eth)
    let leg = TransactionLeg(
      accountId: nil, instrument: eth, quantity: 3, type: .income,
      earmarkId: earmark.id)
    let txn = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000), payee: "in",
      legs: [leg])

    try await perProfile.write { database in
      try EarmarkRow(domain: earmark).insert(database)
      try TransactionRow(domain: txn).insert(database)
      try TransactionLegRow(domain: leg, transactionId: txn.id, sortOrder: 0)
        .insert(database)
    }
    return SeededRepo(repo: repo, earmarkId: earmark.id, eth: eth)
  }

  @Test("fetchAll position instrument absent from per-profile table resolves via resolver")
  func fetchAllResolvesFromSharedRegistry() async throws {
    let seeded = try await makeSeededRepo()
    let earmarks = try await seeded.repo.fetchAll()
    let resolved = try #require(earmarks.first { $0.id == seeded.earmarkId })
    let position = try #require(resolved.positions.first)
    #expect(position.instrument == seeded.eth)
    #expect(position.instrument.kind == .cryptoToken)
  }

  @Test("observeAll position instrument absent from per-profile table resolves via resolver")
  func observeAllResolvesFromSharedRegistry() async throws {
    let seeded = try await makeSeededRepo()
    var iterator = seeded.repo.observeAll().makeAsyncIterator()
    let first = try #require(await iterator.next())
    let resolved = try #require(first.first { $0.id == seeded.earmarkId })
    let position = try #require(resolved.positions.first)
    #expect(position.instrument == seeded.eth)
    #expect(position.instrument.kind == .cryptoToken)
  }
}

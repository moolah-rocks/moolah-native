// MoolahTests/Backends/GRDB/AcctRepoSharedInstrumentResolutionTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the architectural contract that `GRDBAccountRepository` resolves
/// position instruments via the injected `InstrumentMapResolving` (the
/// shared profile-index registry), not via a read of the per-profile
/// `instrument` table inside its own snapshot.
///
/// The proof is constructed so per-profile resolution *cannot* succeed:
/// the account, transaction, and leg rows are inserted directly into the
/// per-profile database (raw row inserts, no `repo.create`, so no
/// placeholder `instrument` row is planted). The per-profile `instrument`
/// table therefore has **no** row for the crypto instrument. The
/// instrument exists only in the shared registry. If `fetchAll` /
/// `update` still resolve the position to the full crypto `Instrument`
/// (kind `.cryptoToken`) rather than the `Instrument.fiat(code:)`
/// fallback `computePositions` applies on a miss, resolution provably
/// came from the injected resolver.
@Suite("Account reads resolve instruments from the shared registry")
struct AcctRepoSharedInstrumentResolutionTests {
  @Test("fetchAll position instrument absent from per-profile table resolves via resolver")
  func fetchAllResolvesFromSharedRegistry() async throws {
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

    let repo = GRDBAccountRepository(
      database: perProfile, instrumentResolver: registry,
      instrumentRegistrar: registry)

    let account = Account(
      name: "Trust - Ethereum", type: .crypto, instrument: eth,
      valuationMode: .calculatedFromTrades, walletAddress: "0xabc",
      chainId: 1)
    let leg = TransactionLeg(
      accountId: account.id, instrument: eth, quantity: 5, type: .income)
    let txn = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000), payee: "in",
      legs: [leg])

    // Raw row inserts only: the per-profile `instrument` table stays
    // empty for `eth.id`, so any successful resolution must originate
    // from the injected shared registry.
    try await perProfile.write { database in
      try AccountRow(domain: account).insert(database)
      try TransactionRow(domain: txn).insert(database)
      try TransactionLegRow(domain: leg, transactionId: txn.id, sortOrder: 0)
        .insert(database)
    }

    let accounts = try await repo.fetchAll()
    let resolved = try #require(accounts.first { $0.id == account.id })
    let position = try #require(resolved.positions.first)
    #expect(position.instrument == eth)
    #expect(position.instrument.kind == .cryptoToken)
  }

  @Test("update position instrument absent from per-profile table resolves via resolver")
  func updateResolvesFromSharedRegistry() async throws {
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

    let repo = GRDBAccountRepository(
      database: perProfile, instrumentResolver: registry,
      instrumentRegistrar: registry)

    let account = Account(
      name: "Trust - Ethereum", type: .crypto, instrument: eth,
      valuationMode: .calculatedFromTrades, walletAddress: "0xabc",
      chainId: 1)
    let leg = TransactionLeg(
      accountId: account.id, instrument: eth, quantity: 5, type: .income)
    let txn = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000), payee: "in",
      legs: [leg])

    try await perProfile.write { database in
      try AccountRow(domain: account).insert(database)
      try TransactionRow(domain: txn).insert(database)
      try TransactionLegRow(domain: leg, transactionId: txn.id, sortOrder: 0)
        .insert(database)
    }

    let updated = try await repo.update(account)
    let position = try #require(updated.positions.first)
    #expect(position.instrument == eth)
    #expect(position.instrument.kind == .cryptoToken)
  }
}

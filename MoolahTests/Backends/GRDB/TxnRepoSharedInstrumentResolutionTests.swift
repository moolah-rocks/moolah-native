// MoolahTests/Backends/GRDB/TxnRepoSharedInstrumentResolutionTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// `InstrumentMapResolving` whose resolution always fails. Used to drive
/// the resolver-error path of `GRDBTransactionRepository`'s observation
/// pipeline: the error must surface via `observeErrors()` and finish the
/// observation stream.
struct AlwaysThrowingInstrumentMapResolver: InstrumentMapResolving {
  func instrumentMap() async throws -> [String: Instrument] {
    throw CocoaError(.fileNoSuchFile)
  }
}

/// Pins the architectural contract that `GRDBTransactionRepository`
/// resolves leg / target instruments via the injected
/// `InstrumentMapResolving` (the shared profile-index registry), not via
/// a read of the per-profile `instrument` table inside its own snapshot.
///
/// The proof is constructed so per-profile resolution *cannot* succeed:
/// the transaction header, leg, and account rows are inserted directly
/// into the per-profile database (no `repo.create`, so
/// `ensureInstrumentReadable` never plants a placeholder
/// `instrument` row). The per-profile `instrument` table therefore has
/// **no** row for the crypto instrument. The instrument exists only in
/// the shared registry. If `fetch` still returns the full crypto
/// `Instrument` (kind `.cryptoToken`) for both the leg and the page's
/// `targetInstrument` — rather than the `Instrument.fiat(code:
/// "1:native")` fallback `fetchLegs` / `resolveTargetInstrument` apply
/// on a miss — resolution provably came from the injected resolver.
@Suite("Transaction reads resolve instruments from the shared registry")
struct TxnRepoSharedInstrumentResolutionTests {
  @Test("leg instrument absent from per-profile table resolves via resolver")
  func resolvesFromSharedRegistry() async throws {
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

    let repo = GRDBTransactionRepository(
      database: perProfile,
      defaultInstrument: Instrument.fiat(code: "USD"),
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)

    let account = Account(
      name: "Trust - Ethereum", type: .crypto, instrument: eth,
      valuationMode: .calculatedFromTrades, walletAddress: "0xabc",
      chainId: 1)
    let leg = TransactionLeg(
      accountId: account.id, instrument: eth, quantity: 1, type: .income)
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

    let page = try await repo.fetch(
      filter: TransactionFilter(accountId: account.id), page: 0,
      pageSize: 50)

    let resolvedLeg = try #require(page.transactions.first?.legs.first)
    #expect(resolvedLeg.instrument == eth)
    #expect(resolvedLeg.instrument.kind == .cryptoToken)
    #expect(page.targetInstrument == eth)
    #expect(page.targetInstrument.kind == .cryptoToken)
  }

  @Test("resolver failure surfaces via observeErrors and finishes the stream")
  func resolverFailureSurfacesAndFinishes() async throws {
    let perProfile = try ProfileDatabase.openInMemory()
    let repo = GRDBTransactionRepository(
      database: perProfile,
      defaultInstrument: Instrument.fiat(code: "USD"),
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: AlwaysThrowingInstrumentMapResolver(),
      instrumentRegistrar: (try SharedRegistryTestSupport.makeSharedRegistry()))

    // Start consuming errors before subscribing so the single-shot
    // channel emission cannot be missed.
    var errorIterator = repo.observeErrors().makeAsyncIterator()

    // The resolver throws before any value is produced, so the worker
    // task surfaces the error to the shared channel and finishes the
    // observation continuation — `next()` returns `nil` deterministically
    // (no value is ever yielded), with no sleep required.
    var pageIterator = repo.observe(
      filter: TransactionFilter(), page: 0, pageSize: 50
    ).makeAsyncIterator()
    let firstPage = await pageIterator.next()
    #expect(firstPage == nil, "observe stream must finish on resolver failure")

    let surfaced = await errorIterator.next()
    #expect(surfaced != nil, "resolver error must surface via observeErrors()")
  }
}

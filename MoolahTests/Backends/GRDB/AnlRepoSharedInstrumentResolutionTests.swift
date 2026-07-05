// MoolahTests/Backends/GRDB/AnlRepoSharedInstrumentResolutionTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the architectural contract that `GRDBAnalysisRepository` resolves
/// the per-row instrument via the injected `InstrumentMapResolving` (the
/// shared profile-index registry), not via a read of the per-profile
/// `instrument` table inside its own aggregation snapshot.
///
/// The proof is constructed so per-profile resolution *cannot* succeed:
/// the category, transaction, and leg rows are inserted directly into the
/// per-profile database (raw row inserts, so no placeholder `instrument`
/// row is planted). The per-profile `instrument` table therefore has
/// **no** row for the crypto instrument; it exists only in the shared
/// registry.
///
/// The distinguishing proof is the resolved instrument's *kind*.
/// `InstrumentAmount`'s storage scale is a universal `10^8` constant
/// independent of `Instrument.decimals` (see `InstrumentAmount.swift`
/// `storageScale`), so the decoded `quantity` is `1` whether resolution
/// found the registered crypto instrument *or* fell back to
/// `Instrument.fiat(code:)` — `quantity` alone does not distinguish the
/// two paths. What does distinguish them is `kind`: the registered
/// instrument is `.cryptoToken`, while the on-miss fallback yields a
/// `.fiatCurrency` instrument. Asserting `kind == .cryptoToken` (and
/// equality with the shared `eth` instrument) therefore fails if
/// resolution fell back to the per-profile fiat default, proving the
/// value came from the injected resolver.
@Suite("Analysis reads resolve instruments from the shared registry")
struct AnlRepoSharedInstrumentResolutionTests {
  @Test("category-balances instrument absent from per-profile table resolves via resolver")
  func categoryBalancesResolvesFromSharedRegistry() async throws {
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

    let repo = GRDBAnalysisRepository(
      database: perProfile,
      instrument: Instrument.fiat(code: "USD"),
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry)

    let categoryId = UUID()
    let day = Date(timeIntervalSince1970: 1_700_000_000)
    // One whole ETH at 18 decimals.
    let oneEth = InstrumentAmount(quantity: 1, instrument: eth)
    let leg = TransactionLeg(
      accountId: UUID(), instrument: eth, quantity: oneEth.quantity,
      type: .expense, categoryId: categoryId)
    let txn = Transaction(date: day, payee: "buy", legs: [leg])

    try await perProfile.write { database in
      try TransactionRow(domain: txn).insert(database)
      try TransactionLegRow(domain: leg, transactionId: txn.id, sortOrder: 0)
        .insert(database)
    }

    let balances = try await repo.fetchCategoryBalances(
      dateRange: day.addingTimeInterval(-86_400)...day.addingTimeInterval(86_400),
      transactionType: .expense,
      filters: nil,
      targetInstrument: eth
    ).byCategory

    let amount = try #require(balances[categoryId])
    #expect(amount.instrument == eth)
    #expect(amount.instrument.kind == .cryptoToken)
    #expect(amount.quantity == 1)
  }
}

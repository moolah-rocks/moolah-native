// MoolahTests/Backends/GRDB/InvRepoSharedInstrumentResolutionTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the architectural contract that
/// `GRDBInvestmentRepository.fetchDailyBalances(accountId:)` (via
/// `DailyBalanceCompute`) resolves each leg's instrument through the
/// injected `InstrumentMapResolving` (the shared profile-index
/// registry), not via a read of the per-profile `instrument` table
/// inside its own snapshot.
///
/// The proof is constructed so per-profile resolution *cannot* succeed:
/// the account, transaction, and leg rows are inserted directly into the
/// per-profile database (raw row inserts, so no placeholder `instrument`
/// row is planted). The per-profile `instrument` table therefore has
/// **no** row for the crypto instrument; it exists only in the shared
/// registry.
///
/// The distinguishing proof is the resolved instrument's *kind*.
/// `InstrumentAmount`'s storage scale is a universal `10^8` constant
/// independent of `Instrument.decimals` (see `InstrumentAmount.swift`
/// `storageScale`), so the decoded balance `quantity` is `1` whether
/// resolution found the registered crypto instrument *or* fell back to
/// `Instrument.fiat(code:)` — `quantity` alone does not distinguish the
/// two paths. What does distinguish them is `kind`: the registered
/// instrument is `.cryptoToken`, while the on-miss fallback yields a
/// `.fiatCurrency` instrument. Asserting `kind == .cryptoToken` (and
/// equality with the shared `eth` instrument) therefore fails if
/// resolution fell back to the per-profile default, proving the value
/// came from the injected resolver.
@Suite("Investment daily balances resolve instruments from the shared registry")
struct InvRepoSharedInstrumentResolutionTests {
  @Test("daily-balance leg instrument absent from per-profile table resolves via resolver")
  func dailyBalancesResolveFromSharedRegistry() async throws {
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

    let repo = GRDBInvestmentRepository(
      database: perProfile,
      defaultInstrument: Instrument.fiat(code: "USD"),
      instrumentResolver: registry)

    let account = Account(
      name: "ETH", type: .crypto, instrument: eth,
      valuationMode: .calculatedFromTrades, walletAddress: "0xabc",
      chainId: 1)
    let day = Date(timeIntervalSince1970: 1_700_000_000)
    let leg = TransactionLeg(
      accountId: account.id, instrument: eth,
      quantity: InstrumentAmount(quantity: 1, instrument: eth).quantity,
      type: .income)
    let txn = Transaction(date: day, payee: "in", legs: [leg])

    try await perProfile.write { database in
      try AccountRow(domain: account).insert(database)
      try TransactionRow(domain: txn).insert(database)
      try TransactionLegRow(domain: leg, transactionId: txn.id, sortOrder: 0)
        .insert(database)
    }

    let balances = try await repo.fetchDailyBalances(accountId: account.id)
    let last = try #require(balances.last)
    #expect(last.balance.instrument == eth)
    #expect(last.balance.instrument.kind == .cryptoToken)
    #expect(last.balance.quantity == 1)
  }
}

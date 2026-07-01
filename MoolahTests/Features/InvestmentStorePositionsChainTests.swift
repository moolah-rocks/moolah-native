import Foundation
import Testing

@testable import Moolah

/// Proves that a position-tracked account's owning chain propagates from the
/// `Account` through `InvestmentStore.valuatePositions` into the folded
/// `AssetHolding.contributingChainIds`. This is the per-account valuation
/// path (`loadPositions(accountId:)` sums one account's legs), so each
/// `ValuedPosition` carries exactly one owning chain.
@Suite("InvestmentStore — position chain propagation")
@MainActor
struct InvestmentStorePositionsChainTests {
  let aud = Instrument.fiat(code: "AUD")
  let eth = Instrument.crypto(
    chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)

  @Test("An Optimism (chainId 10) ETH holding folds with contributingChainIds == [10]")
  func opChainPropagatesIntoFold() async throws {
    let accountId = UUID()
    let (backend, database) = try TestBackend.create()
    try await TestBackend.register(eth, in: backend)

    // On-chain crypto wallet on Optimism (chainId 10) holding 2 ETH,
    // valued from trades.
    let account = Account(
      id: accountId,
      name: "OP Wallet",
      type: .crypto,
      instrument: aud,
      valuationMode: .calculatedFromTrades,
      walletAddress: "0xabc",
      chainId: 10)
    TestBackend.seed(accounts: [account], in: database)

    TestBackend.seed(
      transactions: [
        Transaction(
          id: UUID(),
          date: Date(),
          legs: [
            TransactionLeg(
              accountId: accountId, instrument: eth, quantity: Decimal(2), type: .trade)
          ]
        )
      ], in: database)

    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([eth.id: dec("3000.00")])
    )

    // Real production entry point: passes `account.chainId` down the
    // per-account load → valuate chain.
    await store.reloadPositionsIfNeeded(account: account, profileCurrency: aud)

    let ethValued = try #require(store.valuedPositions.first { $0.instrument == eth })
    #expect(ethValued.accountChainId == 10)

    let holdings = AssetHolding.fold(
      store.valuedPositions, assetKeys: [:], hostCurrency: aud)
    let ethHolding = try #require(
      holdings.first { $0.contributingInstrumentIds.contains(eth.id) })
    #expect(ethHolding.contributingChainIds.contains(10))
    #expect(ethHolding.chainId == 10)
  }
}

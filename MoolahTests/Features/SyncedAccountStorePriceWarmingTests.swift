import Foundation
import GRDB
import Testing
import os

@testable import Moolah

/// A spy `PriceWarming` that records the transactions and account ids it
/// was warmed with. `@unchecked Sendable` because the recorded state is
/// guarded by an `OSAllocatedUnfairLock`.
final class SpyPriceWarmer: PriceWarming, @unchecked Sendable {
  private let lock = OSAllocatedUnfairLock(
    initialState: (txns: [Transaction](), accountIds: Set<UUID>(), called: false))

  func warm(transactions: [Transaction], accountIds: Set<UUID>) async {
    lock.withLock { $0 = (transactions, accountIds, true) }
  }

  var called: Bool { lock.withLock { $0.called } }
  var transactions: [Transaction] { lock.withLock { $0.txns } }
  var accountIds: Set<UUID> { lock.withLock { $0.accountIds } }
}

/// Verifies `SyncedAccountStore` kicks off a background crypto-price warm
/// after a wallet apply, exposes a `priceWarmingInProgress` flag that
/// toggles true → false across the warm task, and passes the synced
/// crypto transactions to the injected warmer. See issue #1075.
@Suite("SyncedAccountStore — price warming")
@MainActor
struct SyncedAccountStorePriceWarmingTests {
  nonisolated static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeStore(
    backend: CloudKitBackend, priceWarmer: any PriceWarming
  ) -> SyncedAccountStore {
    let walletApplyEngine = WalletApplyEngine(
      transactions: backend.transactions,
      walletSyncState: backend.walletSyncState,
      importRules: NoOpWalletImportRulesEngine(),
      clock: { Self.pinnedNow })
    return SyncedAccountStore(
      sources: [],
      walletApplyEngine: walletApplyEngine,
      walletSyncState: backend.walletSyncState,
      accounts: backend.accounts,
      transferDetection: TransferDetectionCoordinator(
        transactions: backend.transactions,
        suggestions: backend.transferSuggestions,
        clock: { Self.pinnedNow }),
      clock: { Self.pinnedNow },
      priceWarmer: priceWarmer)
  }

  private func cryptoTxn(account: UUID) -> Transaction {
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    return Transaction(
      date: Self.pinnedNow,
      payee: "buy",
      legs: [TransactionLeg(accountId: account, instrument: eth, quantity: 1, type: .trade)])
  }

  @Test("startPriceWarming invokes the warmer with the synced crypto txns and resets the flag")
  func warmsAfterApply() async throws {
    let (backend, _) = try TestBackend.create()
    let spy = SpyPriceWarmer()
    let store = makeStore(backend: backend, priceWarmer: spy)

    let accountId = UUID()
    let txn = cryptoTxn(account: accountId)

    store.startPriceWarming(genuinelyNew: [txn], accountIds: [accountId])
    await store.waitForPriceWarming()

    #expect(spy.called)
    #expect(!spy.transactions.isEmpty)
    #expect(spy.accountIds == [accountId])
    #expect(store.priceWarmingInProgress == false)
  }

  @Test("no warm is kicked off when there are no genuinely-new transactions")
  func noWarmWithoutNewTransactions() async throws {
    let (backend, _) = try TestBackend.create()
    let spy = SpyPriceWarmer()
    let store = makeStore(backend: backend, priceWarmer: spy)

    store.startPriceWarming(genuinelyNew: [], accountIds: [UUID()])
    await store.waitForPriceWarming()

    #expect(spy.called == false)
    #expect(store.priceWarmingInProgress == false)
  }
}

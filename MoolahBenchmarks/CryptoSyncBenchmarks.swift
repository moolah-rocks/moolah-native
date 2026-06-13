import Foundation
import GRDB
import XCTest

@testable import Moolah

/// Benchmarks for the crypto wallet sync pipeline per
/// `plans/2026-05-05-crypto-wallet-import-design.md` §"Benchmarks". Each
/// test isolates one stage so regressions in fetch vs build vs apply vs
/// dedup can be pinpointed by xctest output and the matching
/// `Signposts.cryptoSync` regions in Instruments.
///
/// Fixtures are synthesised in-memory; the benchmark `AlchemyClient`
/// returns canned `[AlchemyTransfer]` lists so the pipeline measures
/// Swift work — building, merging, dedup, persistence, rules — rather
/// than network variance.
final class CryptoSyncBenchmarks: XCTestCase {

  private var metrics: [XCTMetric] { [XCTClockMetric(), XCTMemoryMetric()] }
  private var options: XCTMeasureOptions {
    let opts = XCTMeasureOptions()
    opts.iterationCount = 10
    return opts
  }

  // MARK: - Single-wallet full sync

  /// Full sync of one wallet with 500 historical transfers. Exercises
  /// `WalletSyncEngine.build` (fetch + group + transfer event build) plus
  /// `WalletApplyEngine.apply` (merge → dedup → persist → rules →
  /// sync-state) end-to-end. Fresh `TestBackend` per iteration so dedup
  /// always sees an empty repository — measures the cold-cache write
  /// path, not the dedup-against-existing path.
  func testCryptoSync_singleWallet_500txs() {
    measure(metrics: metrics, options: options) {
      awaitSyncExpecting { @MainActor in
        let wallets: [BenchmarkWallet] = [.eth1]
        let transfers = BenchmarkAlchemyFixtures.makeNativeTransfers(
          wallet: wallets[0], count: 500)
        let scripted = [wallets[0].address.lowercased(): transfers]
        try await Self.runSyncCycle(wallets: wallets, scripted: scripted)
      }
    }
  }

  /// Concurrent sync of 5 accounts. Exercises the parallel-build phase
  /// of `SyncedAccountStore.syncAccounts` (`withTaskGroup` with concurrency
  /// cap = 4) followed by the sequential apply pass. Each wallet has
  /// 100 transfers so the total work is comparable to the single-wallet
  /// 500-tx benchmark while measuring the parallel scheduling cost.
  func testCryptoSync_5wallets_parallel() {
    measure(metrics: metrics, options: options) {
      awaitSyncExpecting { @MainActor in
        let wallets: [BenchmarkWallet] = [.eth1, .eth2, .eth3, .eth4, .eth5]
        let scripted = BenchmarkAlchemyFixtures.makeNativeTransfers(
          wallets: wallets, perWallet: 100)
        try await Self.runSyncCycle(wallets: wallets, scripted: scripted)
      }
    }
  }

  /// Re-sync overhead: 500 new transfers arrive against 5 000 already
  /// persisted with the same `(accountId, externalId)` shape the dedup
  /// step inspects. The 500 new ones hit the empty-leg path; the 5 000
  /// existing ones force the legExists query to do real work. Designed
  /// to surface an O(n) regression in the dedup loop or a missing index
  /// on `(accountId, externalId)`.
  func testCryptoSync_dedup_500new_against_5000existing() {
    measure(metrics: metrics, options: options) {
      awaitSyncExpecting { @MainActor in
        let wallet = BenchmarkWallet.eth1
        let newTransfers = BenchmarkAlchemyFixtures.makeNativeTransfers(
          wallet: wallet, count: 500, hashOffset: 5_000)
        let scripted = [wallet.address.lowercased(): newTransfers]
        let (backend, _) = try TestBackend.create()
        let accountId = try await Self.seedAccount(for: wallet, in: backend)
        try await Self.preseedTransactions(
          accountId: accountId, count: 5_000, in: backend)
        let store = try Self.makeStore(
          backend: backend,
          alchemy: ScriptedBenchmarkAlchemyClient(transfersByWallet: scripted))
        await store.syncAccounts(try await Self.fetchAccounts(in: backend))
      }
    }
  }

  // MARK: - Token discovery

  /// Discovery + resolution overhead: 50 distinct ERC-20 contract
  /// addresses, none seeded in the registry. The discovery actor must
  /// resolve each one (stubbed resolver returns `.priced` instantly),
  /// then `WalletApplyEngine` persists the resulting transactions with
  /// the resolved instruments. Measures coalescer overhead + registry
  /// upsert cost rather than network round-trips.
  func testCryptoSync_tokenDiscovery_50newtokens() {
    measure(metrics: metrics, options: options) {
      awaitSyncExpecting { @MainActor in
        let wallets: [BenchmarkWallet] = [.eth1]
        let transfers = BenchmarkAlchemyFixtures.makeERC20Transfers(
          wallet: wallets[0], count: 50)
        let scripted = [wallets[0].address.lowercased(): transfers]
        try await Self.runSyncCycle(wallets: wallets, scripted: scripted)
      }
    }
  }

  // MARK: - Cross-device deduper

  /// Deduper sweep cost: 100 duplicate-leg pairs in the repository, all
  /// with `externalId`s in the touched set. Exercises
  /// `CrossDeviceLegDeduper.planCollapse` (group + lex-min winner +
  /// per-transaction wholly-duplicate classification) plus the
  /// `delete(id:)` calls. No sync; just the deduper sweep.
  func testCryptoSync_crossDeviceDeduper_100duplicates() {
    measure(metrics: metrics, options: options) {
      awaitSyncExpecting { @MainActor in
        let (backend, database) = try TestBackend.create()
        // Drop the partial unique index so the seed can plant the same
        // `(accountId, externalId)` pair twice — that's the cross-device
        // race state the deduper exists to clean up.
        try Self.dropDedupIndex(in: database)
        let accountId = try await Self.seedAccount(
          for: .eth1, in: backend)
        let touched = try await Self.preseedDuplicatePairs(
          accountId: accountId, pairCount: 100, in: backend)
        let deduper = CrossDeviceLegDeduper(transactions: backend.transactions)
        _ = try await deduper.dedup(touchedExternalIds: touched)
      }
    }
  }

  // MARK: - Helpers

  /// Drives one full sync cycle through `SyncedAccountStore.syncAccounts`
  /// with the given scripted Alchemy responses. Each call constructs a
  /// fresh `TestBackend` so iteration N starts from an empty repository
  /// — the benchmarks measure cold sync cost, not warm-cache cost.
  @MainActor
  private static func runSyncCycle(
    wallets: [BenchmarkWallet],
    scripted: [String: [AlchemyTransfer]]
  ) async throws {
    let (backend, _) = try TestBackend.create()
    for wallet in wallets {
      _ = try await Self.seedAccount(for: wallet, in: backend)
    }
    let store = try Self.makeStore(
      backend: backend,
      alchemy: ScriptedBenchmarkAlchemyClient(transfersByWallet: scripted))
    let accounts = try await Self.fetchAccounts(in: backend)
    await store.syncAccounts(accounts)
  }

  /// Builds a `SyncedAccountStore` with the given Alchemy stub. Uses an
  /// in-memory token resolver and the no-op rules engine so the
  /// benchmark only measures pipeline-internal work.
  @MainActor
  private static func makeStore(
    backend: CloudKitBackend,
    alchemy: any AlchemyClient
  ) throws -> SyncedAccountStore {
    let registry = StubInstrumentRegistry()
    let resolver = BenchmarkRegistrationResolver()
    let discovery = CryptoTokenDiscoveryService(
      registry: registry, resolver: resolver)
    let walletSyncEngine = WalletSyncEngine(
      alchemy: alchemy,
      blockExplorer: EmptyBlockExplorerStub(),
      discovery: discovery,
      walletSyncState: backend.walletSyncState,
      importOriginFactory: { accountId in
        ImportOrigin(
          rawDescription: "wallet:\(accountId.uuidString)",
          rawAmount: 0,
          importedAt: Self.pinnedNow,
          importSessionId: Self.pinnedSessionId,
          parserIdentifier: "alchemy-wallet-sync")
      })
    let walletApplyEngine = WalletApplyEngine(
      transactions: backend.transactions,
      walletSyncState: backend.walletSyncState,
      importRules: NoOpWalletImportRulesEngine(),
      clock: { Self.pinnedNow })
    return SyncedAccountStore(
      sources: [WalletSyncSource(engine: walletSyncEngine)],
      walletApplyEngine: walletApplyEngine,
      walletSyncState: backend.walletSyncState,
      accounts: backend.accounts,
      transferDetection: TransferDetectionCoordinator(
        transactions: backend.transactions,
        suggestions: backend.transferSuggestions,
        clock: { Self.pinnedNow }),
      clock: { Self.pinnedNow },
      staleThreshold: 0)
  }

  @MainActor
  private static func seedAccount(
    for wallet: BenchmarkWallet,
    in backend: CloudKitBackend
  ) async throws -> UUID {
    let account = Account(
      id: wallet.accountId,
      name: "Wallet \(wallet.address.suffix(4))",
      type: .crypto,
      instrument: ChainConfig.ethereum.nativeInstrument,
      walletAddress: wallet.address.lowercased(),
      chainId: ChainConfig.ethereum.chainId)
    _ = try await backend.accounts.create(account, openingBalance: nil)
    return account.id
  }

  @MainActor
  private static func fetchAccounts(in backend: CloudKitBackend) async throws -> [Account] {
    try await backend.accounts.fetchAll()
  }

  /// Drops the partial unique index that prevents duplicate
  /// `(accountId, externalId)` rows. Lives in a `nonisolated` helper so
  /// the synchronous GRDB write overload gets selected from inside the
  /// `@MainActor`-isolated measure body — calling `database.write` from
  /// an async context resolves to the awaitable overload, which then
  /// requires the body to be sendable.
  nonisolated private static func dropDedupIndex(in database: DatabaseQueue) throws {
    try database.write { database in
      try database.execute(sql: "DROP INDEX IF EXISTS leg_dedup_by_account_external")
    }
  }

  /// Pre-seeds `count` transactions with `(accountId, externalId)` legs
  /// so a subsequent sync's per-leg dedup has real lookups to perform.
  @MainActor
  private static func preseedTransactions(
    accountId: UUID,
    count: Int,
    in backend: CloudKitBackend
  ) async throws {
    for index in 0..<count {
      let leg = TransactionLeg(
        accountId: accountId,
        instrument: ChainConfig.ethereum.nativeInstrument,
        quantity: -1,
        externalId: BenchmarkAlchemyFixtures.hashFor(index: index),
        type: .transfer)
      _ = try await backend.transactions.create(
        Transaction(
          date: Self.pinnedNow.addingTimeInterval(TimeInterval(-index * 60)),
          legs: [leg]))
    }
  }

  /// Plants `pairCount` pairs of duplicate transactions sharing the
  /// same `(accountId, externalId)`. Returns the set of `externalId`s
  /// touched — the input the deduper takes.
  @MainActor
  private static func preseedDuplicatePairs(
    accountId: UUID,
    pairCount: Int,
    in backend: CloudKitBackend
  ) async throws -> Set<String> {
    var externalIds: Set<String> = []
    externalIds.reserveCapacity(pairCount)
    for index in 0..<pairCount {
      let externalId = BenchmarkAlchemyFixtures.hashFor(index: index)
      externalIds.insert(externalId)
      for variant in 0..<2 {
        let leg = TransactionLeg(
          accountId: accountId,
          instrument: ChainConfig.ethereum.nativeInstrument,
          quantity: -1,
          externalId: externalId,
          type: .transfer)
        _ = try await backend.transactions.create(
          Transaction(
            date: Self.pinnedNow.addingTimeInterval(
              TimeInterval(-index * 60 - variant)),
            legs: [leg]))
      }
    }
    return externalIds
  }

  /// Pinned clock so successive runs are deterministic — `WalletSyncState`
  /// rows record the same `lastSyncedAt`, so seed comparisons stay stable.
  nonisolated static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)
  /// Pinned session id so `ImportOrigin.importSessionId` is identical
  /// across iterations.
  nonisolated static let pinnedSessionId =
    UUID(
      uuidString: "BENCBEEF-0000-0000-0000-000000000001") ?? UUID()
}

// Benchmark wallets, fixtures and scripted Alchemy / resolver stubs live
// in `CryptoSyncBenchmarkSupport.swift`.

/// No-op `BlockExplorerClient` for benchmarks that only measure the
/// Alchemy-path work. Returns empty lists so the engine's Blockscout
/// path adds no network variance to the measured pipeline work.
private struct EmptyBlockExplorerStub: BlockExplorerClient {
  func nativeTransactions(
    chain: ChainConfig, walletAddress: String, fromBlock: UInt64
  ) async throws -> [BlockscoutTransaction] { [] }
  func internalTransactions(
    chain: ChainConfig, walletAddress: String, fromBlock: UInt64
  ) async throws -> [BlockscoutInternalTx] { [] }
}

// MoolahTests/Features/Sync/SyncedAccountStoreFullResyncTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests for `SyncedAccountStore.syncAccount(_:fullResync:)` — the backend
/// for the user-triggered "full re-sync" of a synced crypto account. Split
/// out of `SyncedAccountStoreTests.swift` to keep both files under the
/// project's `file_length` / `type_body_length` budget; duplicates the
/// `Fixture` / `makeStore` / `seedCryptoAccount` harness rather than
/// sharing it, matching the existing split in
/// `SyncedAccountStoreGlobalErrorTests.swift`.
@Suite("SyncedAccountStore — full resync")
@MainActor
struct SyncedAccountStoreFullResyncTests {
  /// Pinned clock value tests assert against.
  nonisolated static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)

  private struct Fixture {
    let store: SyncedAccountStore
    let backend: CloudKitBackend
    let database: DatabaseQueue
    let alchemy: RecordingAlchemyClientStub
  }

  private func makeStore() throws -> Fixture {
    let (backend, database) = try TestBackend.create()
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let registry = backend.grdbInstruments
    let discovery = CryptoTokenDiscoveryService(
      registry: registry,
      resolver: CountingRegistrationResolver())
    let walletSyncEngine = WalletSyncEngine(
      alchemy: alchemy,
      blockExplorer: BlockExplorerTestDoubles.empty,
      discovery: discovery,
      walletSyncState: backend.walletSyncState,
      importOriginFactory: { accountId in
        ImportOrigin(
          rawDescription: "wallet:\(accountId.uuidString)",
          rawAmount: 0,
          importedAt: Self.pinnedNow,
          importSessionId: UUID(),
          parserIdentifier: "alchemy-wallet-sync")
      })
    let walletApplyEngine = WalletApplyEngine(
      transactions: backend.transactions,
      walletSyncState: backend.walletSyncState,
      importRules: NoOpWalletImportRulesEngine(),
      clock: { Self.pinnedNow })
    let store = SyncedAccountStore(
      sources: [WalletSyncSource(engine: walletSyncEngine)],
      walletApplyEngine: walletApplyEngine,
      walletSyncState: backend.walletSyncState,
      accounts: backend.accounts,
      transferDetection: TransferDetectionCoordinator(
        transactions: backend.transactions,
        suggestions: backend.transferSuggestions,
        clock: { Self.pinnedNow }),
      clock: { Self.pinnedNow })
    return Fixture(
      store: store, backend: backend, database: database, alchemy: alchemy)
  }

  private func seedCryptoAccount(
    in database: DatabaseQueue,
    walletAddress: String = "0x" + String(UUID().uuidString.prefix(40)),
    chain: ChainConfig = .ethereum
  ) -> Account {
    let account = Account(
      name: "Wallet \(walletAddress.suffix(4))",
      type: .crypto,
      instrument: chain.nativeInstrument,
      walletAddress: walletAddress.lowercased(),
      chainId: chain.chainId)
    _ = TestBackend.seed(accounts: [account], in: database)
    return account
  }

  @Test("syncAccount(fullResync: true) forces fromBlock 0 and re-establishes the checkpoint")
  func fullResyncForcesFromBlockZero() async throws {
    let fixture = try makeStore()
    let account = seedCryptoAccount(in: fixture.database)
    // Recent lastSyncedAt — a normal sync wouldn't be stale — proves the
    // reset is driven by the explicit flag, not staleness.
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 5_000,
        lastSyncedAt: Self.pinnedNow, lastError: nil))
    await fixture.store.loadInitialState()

    await fixture.store.syncAccount(account, fullResync: true)

    #expect(fixture.alchemy.recordedCalls.count == 1)
    #expect(fixture.alchemy.recordedCalls.first?.fromBlock == 0)
    // The apply pass re-saves a checkpoint row after the reset — the
    // reset is not left as a dangling "never synced" state.
    let saved = try await fixture.backend.walletSyncState.load(accountId: account.id)
    #expect(saved != nil)
  }

  @Test("syncAccount without fullResync keeps the watermark-derived fromBlock")
  func incrementalSyncKeepsWatermark() async throws {
    let fixture = try makeStore()
    let account = seedCryptoAccount(in: fixture.database)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 5_000,
        lastSyncedAt: Self.pinnedNow, lastError: nil))
    await fixture.store.loadInitialState()

    await fixture.store.syncAccount(account)

    #expect(fixture.alchemy.recordedCalls.count == 1)
    // 5_000 − 32 reorg window (WalletSyncEngine.subtractingReorgWindow).
    #expect(fixture.alchemy.recordedCalls.first?.fromBlock == 4_968)
  }

  @Test("syncAccount(fullResync: true) is a no-op when the account is already in flight")
  func fullResyncRespectsInFlightMarker() async throws {
    let fixture = try makeStore()
    let account = seedCryptoAccount(in: fixture.database)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 5_000,
        lastSyncedAt: Self.pinnedNow, lastError: nil))
    await fixture.store.loadInitialState()

    // Launch two full-resync triggers concurrently. The in-flight guard
    // must run before the checkpoint delete, so only one Alchemy call
    // fires and the duplicate collapses without also stripping the
    // watermark out from under the winning run.
    async let firstRun: Void = fixture.store.syncAccount(account, fullResync: true)
    async let duplicate: Void = fixture.store.syncAccount(account, fullResync: true)
    _ = await (firstRun, duplicate)

    #expect(fixture.alchemy.recordedCalls.count == 1)
  }
}

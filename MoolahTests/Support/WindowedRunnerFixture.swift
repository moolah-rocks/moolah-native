// MoolahTests/Support/WindowedRunnerFixture.swift
import Foundation
import GRDB

@testable import Moolah

/// Shared wiring for the `WindowedWalletSyncRunner` unit suites. Builds a
/// runner over a REAL `WalletApplyEngine` + in-memory GRDB backend so the
/// checkpoint / `WalletSyncState` writes are genuine — the whole point of the
/// feature is that an interrupted scan leaves a correct, resumable checkpoint.
/// The `ChainDataClient` is a scripted `ScriptedWindowChainClient` (per-window
/// ERC-20 rows, recorded `fromBlock`s, injectable per-window failure); the
/// Blockscout double defaults to empty and can be overridden to exercise the
/// native-row partition path.
///
/// This mirrors `WindowedSyncStore` (the equivalent harness for the
/// `SyncedAccountStore` routing suites) one level down: it wires the runner
/// directly rather than a whole store, so the runner suites share one
/// construction site instead of re-deriving it per file.
enum WindowedRunnerFixture {
  nonisolated static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)
  nonisolated static let wallet = "0x1111111111111111111111111111111111111111"
  nonisolated static let counterparty = "0x2222222222222222222222222222222222222222"
  /// The reorg window `WalletSyncEngine.resolveFromBlock` subtracts.
  nonisolated static let reorgWindow: UInt64 = 32

  struct Setup {
    let backend: CloudKitBackend
    let database: DatabaseQueue
    let chain: ScriptedWindowChainClient
    let runner: WindowedWalletSyncRunner

    func seedAccount(
      walletAddress: String = WindowedRunnerFixture.wallet
    ) -> Account {
      let account = makeCryptoAccount(walletAddress: walletAddress, chain: .ethereum)
      _ = TestBackend.seed(accounts: [account], in: database)
      return account
    }
  }

  @MainActor
  static func make(
    head: UInt64?,
    segmentBlockWindow: UInt64 = 250_000,
    blockExplorer: RecordingBlockExplorerClientStub = BlockExplorerTestDoubles.empty
  ) throws -> Setup {
    let (backend, database) = try TestBackend.create()
    let chain = ScriptedWindowChainClient(head: head)
    // Wire discovery to the backend's shared registry (matches production)
    // so an ERC-20 instrument the engine resolves is registered where the
    // apply pass's persistence reads it back.
    let discovery = CryptoTokenDiscoveryService(
      registry: backend.grdbInstruments, resolver: CountingRegistrationResolver())
    let engine = WalletSyncEngine(
      alchemy: chain,
      blockExplorer: blockExplorer,
      discovery: discovery,
      walletSyncState: backend.walletSyncState,
      checkpoints: backend.walletSyncCheckpoints,
      importOriginFactory: { makeWalletImportOrigin(for: $0) })
    let applyEngine = WalletApplyEngine(
      transactions: backend.transactions,
      walletSyncState: backend.walletSyncState,
      checkpoints: backend.walletSyncCheckpoints,
      importRules: NoOpWalletImportRulesEngine(),
      clock: { pinnedNow })
    let runner = WindowedWalletSyncRunner(
      engine: engine,
      chainClient: chain,
      applyEngine: applyEngine,
      segmentBlockWindow: segmentBlockWindow)
    return Setup(backend: backend, database: database, chain: chain, runner: runner)
  }
}

import Foundation
import Testing

@testable import Moolah

/// `WalletSyncEngine` `fromBlock` derivation from the cross-device synced
/// checkpoint. Split from `WalletSyncEngineTests` so that suite stays under
/// the type-body-length ceiling.
@Suite("WalletSyncEngine — Synced checkpoint")
struct WalletSyncEngineCheckpointTests {
  private static let wallet = "0x1111111111111111111111111111111111111111"

  @Test("Local absent but synced checkpoint set → fromBlock = synced - 32")
  func fromBlockUsesSyncedCheckpointWhenLocalAbsent() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    // Local per-device state is empty (a fresh device); the cross-device
    // synced checkpoint carries a peer's higher watermark.
    let syncState = RecordingWalletSyncStateRepository()
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let checkpoints = InMemoryWalletSyncCheckpointRepository([
      WalletSyncCheckpoint(id: account.id, lastSyncedBlockNumber: 1000)
    ])
    let subject = makeDiscoverySubject()
    let engine = WalletSyncEngine(
      alchemy: alchemy,
      blockExplorer: BlockExplorerTestDoubles.empty,
      discovery: subject.service,
      walletSyncState: syncState,
      checkpoints: checkpoints,
      importOriginFactory: { makeWalletImportOrigin(for: $0) })

    _ = try await engine.build(account: account, chain: .ethereum)

    // priorBlock = max(local 0, synced 1000) = 1000 → fromBlock 1000 - 32.
    #expect(alchemy.recordedCalls.first?.fromBlock == 968)
  }
}

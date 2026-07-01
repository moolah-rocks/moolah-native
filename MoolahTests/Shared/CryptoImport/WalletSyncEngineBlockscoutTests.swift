// MoolahTests/Shared/CryptoImport/WalletSyncEngineBlockscoutTests.swift
import Foundation
import Testing

@testable import Moolah

/// Behavioural tests for `WalletSyncEngine`'s Blockscout integration:
/// Alchemy native rows are dropped and Blockscout is the authoritative
/// native-ETH index; Blockscout failures propagate as `WalletSyncError`
/// without fallback; the reorg-adjusted `fromBlock` is forwarded to
/// Blockscout the same way it is to Alchemy.
@Suite("WalletSyncEngine — Blockscout integration")
struct WalletSyncEngineBlockscoutTests {
  private func makeEngine(
    alchemy: RecordingAlchemyClientStub = .init(),
    blockExplorer: RecordingBlockExplorerClientStub = BlockExplorerTestDoubles.empty,
    syncState: RecordingWalletSyncStateRepository = .init()
  ) -> WalletSyncEngine {
    let subject = makeDiscoverySubject()
    return WalletSyncEngine(
      alchemy: alchemy,
      blockExplorer: blockExplorer,
      discovery: subject.service,
      walletSyncState: syncState,
      importOriginFactory: { accountId in makeWalletImportOrigin(for: accountId) })
  }

  @Test("Alchemy external rows dropped; Blockscout native + Alchemy ERC-20 kept")
  func filtersAlchemyToErc20AndSourcesNativeFromBlockscout() async throws {
    let wallet = "0xa4b572ea1b6f734fc88a0a004c5301f8dad54d60"
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(
      .transfers([
        AlchemyTransfer(
          hash: "0xNAT", uniqueId: "0xNAT:external:0", from: wallet, to: "0xD",
          category: .external, asset: nil,
          rawContract: .init(address: nil, decimal: nil, rawValue: "0x1"),
          metadata: .init(blockTimestamp: "2024-09-12T12:00:00.000000Z"), blockNum: "0x64"),
        AlchemyTransfer(
          hash: "0xERC", uniqueId: "0xERC:erc20:0", from: "0xS", to: wallet,
          category: .erc20, asset: "USDC",
          rawContract: .init(address: "0xtoken", decimal: "0x6", rawValue: "0xf4240"),
          metadata: .init(blockTimestamp: "2024-09-12T12:00:00.000000Z"), blockNum: "0x65"),
      ]))
    let blockscout = RecordingBlockExplorerClientStub()
    blockscout.setNative(
      .txs([
        BlockscoutTransaction(
          hash: "0xNAT", blockNumber: 100, timestamp: "2024-09-12T12:00:00.000000Z",
          from: .init(hash: wallet), to: .init(hash: "0xD"),
          value: "1", status: "ok", result: "success")
      ]))
    let engine = makeEngine(alchemy: alchemy, blockExplorer: blockscout)
    let result = try await engine.build(
      account: makeCryptoAccount(walletAddress: wallet, chain: .ethereum), chain: .ethereum)
    let externalIds = result.candidates.flatMap { $0.transaction.legs.map(\.externalId) }
    #expect(externalIds.contains("0xERC:erc20:0"))  // Alchemy ERC-20 kept
    #expect(externalIds.contains("0xNAT:external:0"))  // native from Blockscout
    #expect(externalIds.filter { $0 == "0xNAT:external:0" }.count == 1)  // no double-count
  }

  @Test("Blockscout failure propagates as WalletSyncError, not swallowed")
  func blockscoutFailurePropagatesAsWalletSyncError() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let blockscout = RecordingBlockExplorerClientStub()
    blockscout.setNative(
      .failure(WalletSyncError.network(underlyingDescription: "blockscout down")))
    let engine = makeEngine(alchemy: alchemy, blockExplorer: blockscout)
    await #expect(throws: WalletSyncError.self) {
      _ = try await engine.build(
        account: makeCryptoAccount(walletAddress: "0xabc", chain: .ethereum), chain: .ethereum)
    }
  }

  @Test("Blockscout receives reorg-adjusted fromBlock from prior sync state")
  func blockscoutReceivesReorgAdjustedFromBlock() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let blockscout = RecordingBlockExplorerClientStub()
    let syncState = RecordingWalletSyncStateRepository()
    let account = makeCryptoAccount(walletAddress: "0xabc", chain: .ethereum)
    syncState.seed(
      WalletSyncState(
        id: account.id,
        lastSyncedBlockNumber: 100,
        lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastError: nil))
    let engine = makeEngine(alchemy: alchemy, blockExplorer: blockscout, syncState: syncState)

    _ = try await engine.build(account: account, chain: .ethereum)

    #expect(blockscout.recordedNativeCalls.first?.fromBlock == 68)  // 100 - 32
    #expect(blockscout.recordedInternalCalls.first?.fromBlock == 68)  // 100 - 32
  }
}

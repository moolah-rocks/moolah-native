// MoolahTests/Shared/CryptoImport/WalletSyncEngineWindowBuildTests.swift
import Foundation
import Testing

@testable import Moolah

/// Behavioural tests for the two primitives Task 3 extracted from
/// `WalletSyncEngine.build`: `fetchNativeContext` (the Blockscout +
/// wrap/unwrap fetch) and `buildWindow` (the windowable ERC-20 fetch +
/// candidate builder). A later windowed sync runner calls these directly
/// per block window; `build` itself is covered separately by
/// `WalletSyncEngineTests` and must keep behaving exactly as before.
@Suite("WalletSyncEngine — Windowed build primitives")
struct WalletSyncEngineWindowBuildTests {
  private static let wallet = "0x1111111111111111111111111111111111111111"
  private static let counterparty = "0x2222222222222222222222222222222222222222"

  private func makeEngine(
    alchemy: RecordingAlchemyClientStub = .init(),
    blockExplorer: RecordingBlockExplorerClientStub = BlockExplorerTestDoubles.empty,
    syncState: RecordingWalletSyncStateRepository = .init(),
    checkpoints: InMemoryWalletSyncCheckpointRepository = .init()
  ) -> WalletSyncEngine {
    let subject = makeDiscoverySubject()
    return WalletSyncEngine(
      alchemy: alchemy,
      blockExplorer: blockExplorer,
      discovery: subject.service,
      walletSyncState: syncState,
      checkpoints: checkpoints,
      importOriginFactory: { accountId in makeWalletImportOrigin(for: accountId) })
  }

  // MARK: - fetchNativeContext

  @Test("Returns the adapted native rows for a scripted Blockscout response")
  func fetchNativeContextReturnsAdaptedNativeRows() async throws {
    let blockscout = RecordingBlockExplorerClientStub()
    blockscout.setNative(
      .txs([
        BlockscoutTransaction(
          hash: "0xNAT", blockNumber: 100, timestamp: "2024-09-12T12:00:00.000000Z",
          from: .init(hash: Self.wallet), to: .init(hash: Self.counterparty),
          value: "1000000000000000000", status: "ok", result: "success")
      ]))
    let engine = makeEngine(blockExplorer: blockscout)
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)

    let context = try await engine.fetchNativeContext(
      account: account, chain: .ethereum, walletAddress: Self.wallet, fromBlock: 50)

    let externalIds = context.nativeRows.map(\.uniqueId)
    #expect(externalIds.contains("0xNAT:external:0"))
    #expect(blockscout.recordedNativeCalls.first?.fromBlock == 50)
  }

  // MARK: - buildWindow

  @Test(
    """
    buildWindow(window:100...200) merges the ERC-20 fetch with the supplied \
    native row and records headForRecord as the window end
    """)
  func buildWindowMergesErc20AndNativeRowsWithWindowEndAsHead() async throws {
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(
      .transfers([
        makeAlchemyTransfer(
          hash: "0xERC", from: Self.counterparty, to: Self.wallet, category: .erc20,
          contractAddress: "0xtoken", decimalsHex: "0x12", blockNum: "0xc8"),  // 200
        // Non-erc20 categories returned by Alchemy's window fetch must be
        // filtered out — only Blockscout-sourced native rows (supplied via
        // `nativeRowsInWindow`) should represent native movement.
        makeAlchemyTransfer(
          hash: "0xEXT", from: Self.counterparty, to: Self.wallet, category: .external,
          blockNum: "0xc8"),
      ]))
    let engine = makeEngine(alchemy: alchemy)
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)
    let nativeRow = makeAlchemyTransfer(
      hash: "0xNAT", from: Self.counterparty, to: Self.wallet, category: .external,
      blockNum: "0x64")  // 100

    let result = try await engine.buildWindow(
      account: account, chain: .ethereum, walletAddress: Self.wallet,
      window: 100...200,
      headForRecord: 200,
      nativeRowsInWindow: [nativeRow])

    #expect(result.headBlockNumber == 200)  // window end, not max transfer block
    let externalIds = result.candidates.flatMap { $0.transaction.legs.map(\.externalId) }
    #expect(externalIds.contains("0xERC:0"))  // Alchemy ERC-20 in-window
    #expect(externalIds.contains("0xNAT:0"))  // caller-supplied native row
    #expect(!externalIds.contains("0xEXT:0"))  // non-erc20 Alchemy row dropped

    let call = try #require(alchemy.recordedCalls.first)
    #expect(call.fromBlock == 100)
    #expect(call.toBlock == 200)  // window upper bound forwarded verbatim
  }

  @Test("headForRecord doesn't need to equal the max observed transfer block")
  func headForRecordIsWindowEndEvenWhenLowerThanObservedMax() async throws {
    // A block above the window's own `to` shouldn't happen in production
    // (the fetch itself is bounded), but this asserts buildWindow never
    // derives headBlockNumber from the transfers — it always echoes the
    // caller-supplied window end, unlike `build`'s single-shot watermark.
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let engine = makeEngine(alchemy: alchemy)
    let account = makeCryptoAccount(walletAddress: Self.wallet, chain: .ethereum)

    let result = try await engine.buildWindow(
      account: account, chain: .ethereum, walletAddress: Self.wallet,
      window: 100...200,
      headForRecord: 200)

    #expect(result.headBlockNumber == 200)
    #expect(result.candidates.isEmpty)
  }
}

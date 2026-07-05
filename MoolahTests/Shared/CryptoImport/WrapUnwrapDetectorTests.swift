// MoolahTests/Shared/CryptoImport/WrapUnwrapDetectorTests.swift
import Foundation
import Testing

@testable import Moolah

/// Covers `WrapUnwrapDetector`: synthesizing the missing WETH `.erc20` leg
/// from a receipt's `Deposit`/`Withdrawal` event when a native ETH movement
/// touches a chain's wrapped-native contract. Uses a plain in-memory async
/// stub `ChainDataClient` (no `URLProtocol`, no shared statics) so the suite
/// needs no `.serialized`.
@Suite("WrapUnwrapDetector")
struct WrapUnwrapDetectorTests {
  private static let wallet = "0x1111111111111111111111111111111111111111"
  private static let weth = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"
  private static let depositTopic =
    "0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c"
  private static let withdrawalTopic =
    "0x7fcf532c15f0a6db0bd6d0e038bea71d30d808c7d98cb3bf7268a95bf5081b65"
  private static let blockTimestamp = "2024-09-12T12:34:56.000Z"

  @Test
  func synthesizesWethInFromWrapDeposit() async throws {
    let nativeSend = Self.nativeTransfer(
      category: .external,
      from: Self.wallet,
      to: Self.weth,
      hash: "0xwrap",
      block: "0x10")
    let receipt = Self.receipt(
      hash: "0xwrap",
      logs: [
        ReceiptLog(
          address: Self.weth,
          topics: [Self.depositTopic, RPCHex.addressTopic(Self.wallet)],
          data: "0xde0b6b3a7640000",
          logIndex: 3)
      ])
    let stub = StubChainClient(receipts: ["0xwrap": receipt])
    let detector = WrapUnwrapDetector(chainClient: stub)

    let result = try await detector.detect(
      nativeTransfers: [nativeSend], chain: .ethereum, walletAddress: Self.wallet)

    #expect(result.rows.count == 1)
    let row = try #require(result.rows.first)
    #expect(row.category == .erc20)
    #expect(row.from == Self.weth)
    #expect(row.to == Self.wallet)
    #expect(row.rawContract.address == Self.weth)
    #expect(row.rawContract.decimal == "0x12")
    #expect(row.rawContract.rawValue == "0xde0b6b3a7640000")
    #expect(row.uniqueId == "0xwrap:erc20:3")
    #expect(row.blockNum == "0x10")
    #expect(row.metadata.blockTimestamp == Self.blockTimestamp)
    #expect(await stub.receiptFetchCount == 1)
    #expect(result.receipts["0xwrap"]?.hash == "0xwrap")
  }

  @Test
  func synthesizesWethOutFromUnwrapWithdrawal() async throws {
    let nativeReceive = Self.nativeTransfer(
      category: .internal,
      from: Self.weth,
      to: Self.wallet,
      hash: "0xunwrap",
      block: "0x20")
    let receipt = Self.receipt(
      hash: "0xunwrap",
      logs: [
        ReceiptLog(
          address: Self.weth,
          topics: [Self.withdrawalTopic, RPCHex.addressTopic(Self.wallet)],
          data: "0x1bc16d674ec80000",
          logIndex: 5)
      ])
    let stub = StubChainClient(receipts: ["0xunwrap": receipt])
    let detector = WrapUnwrapDetector(chainClient: stub)

    let result = try await detector.detect(
      nativeTransfers: [nativeReceive], chain: .ethereum, walletAddress: Self.wallet)

    #expect(result.rows.count == 1)
    let row = try #require(result.rows.first)
    #expect(row.category == .erc20)
    #expect(row.from == Self.wallet)
    #expect(row.to == Self.weth)
    #expect(row.rawContract.rawValue == "0x1bc16d674ec80000")
    #expect(row.uniqueId == "0xunwrap:erc20:5")
    #expect(row.blockNum == "0x20")
  }

  @Test
  func ignoresNativeSendToNonWrappedAddress() async throws {
    let plainSend = Self.nativeTransfer(
      category: .external,
      from: Self.wallet,
      to: "0x2222222222222222222222222222222222222222",
      hash: "0xplain",
      block: "0x10")
    let stub = StubChainClient(receipts: [:])
    let detector = WrapUnwrapDetector(chainClient: stub)

    let result = try await detector.detect(
      nativeTransfers: [plainSend], chain: .ethereum, walletAddress: Self.wallet)

    #expect(result.rows.isEmpty)
    #expect(result.receipts.isEmpty)
    #expect(await stub.receiptFetchCount == 0)
  }

  // MARK: - Fixtures

  private static func nativeTransfer(
    category: AlchemyTransferCategory,
    from: String,
    to: String,
    hash: String,
    block: String
  ) -> AlchemyTransfer {
    AlchemyTransfer(
      hash: hash,
      uniqueId: "\(hash):\(category.rawValue):0",
      from: from,
      to: to,
      category: category,
      asset: nil,
      rawContract: AlchemyTransfer.RawContract(
        address: nil, decimal: nil, rawValue: "0xde0b6b3a7640000"),
      metadata: AlchemyTransfer.Metadata(blockTimestamp: blockTimestamp),
      blockNum: block)
  }

  private static func receipt(hash: String, logs: [ReceiptLog]) -> AlchemyTransactionReceipt {
    AlchemyTransactionReceipt(
      hash: hash,
      gasUsed: Decimal(21_000),
      effectiveGasPrice: Decimal(1_000_000_000),
      from: wallet,
      logs: logs)
  }
}

/// In-memory async `ChainDataClient` stub for the wrap/unwrap tests. Returns
/// canned receipts keyed by hash and records how many receipt fetches the
/// detector performed so a test can assert non-candidate transfers trigger
/// none. An `actor` (rather than a `URLProtocol`) so it satisfies the async
/// protocol requirements and stays `Sendable` without shared statics.
actor StubChainClient: ChainDataClient {
  private let receipts: [String: AlchemyTransactionReceipt]
  private(set) var receiptFetchCount = 0

  init(receipts: [String: AlchemyTransactionReceipt]) {
    self.receipts = receipts
  }

  func getAssetTransfers(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64
  ) async throws -> [AlchemyTransfer] {
    []
  }

  func getTransactionReceipt(
    chain: ChainConfig,
    hash: String
  ) async throws -> AlchemyTransactionReceipt {
    receiptFetchCount += 1
    guard let receipt = receipts[hash] else {
      throw WalletSyncError.providerMalformedResponse(stage: "getTransactionReceipt")
    }
    return receipt
  }
}

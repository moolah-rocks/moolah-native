// MoolahTests/Shared/CryptoImport/LogTransferMapperTests.swift
import Foundation
import Testing

@testable import Moolah

/// Contract tests for `LogTransferMapper` — maps one ERC-20 `Transfer` log
/// (`RPCLog`) into the canonical `AlchemyTransfer` model so the rest of the
/// pipeline (built on Alchemy's higher-level API) can consume direct-RPC
/// logs unmodified.
@Suite("LogTransferMapper")
struct LogTransferMapperTests {
  /// A canonical USDC `Transfer(address,address,uint256)` log: 6 decimals,
  /// transferring 1_000_000 raw units (1.0 USDC) from one address to
  /// another.
  private static func usdcTransferLog(
    topics: [String] = [
      "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3e",
      "0x000000000000000000000000aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "0x000000000000000000000000bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    ]
  ) -> RPCLog {
    RPCLog(
      address: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      topics: topics,
      data: "0xf4240",
      blockNumber: "0x123abc",
      transactionHash: "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
      logIndex: "0x2"
    )
  }

  @Test("erc20Transfer maps a canonical USDC Transfer log")
  func erc20TransferMapsCanonicalLog() {
    let log = Self.usdcTransferLog()
    let timestamp = Date(timeIntervalSince1970: 1_726_144_496)  // 2024-09-12T12:34:56Z

    let transfer = LogTransferMapper.erc20Transfer(
      from: log, decimals: 6, symbol: "USDC", timestamp: timestamp)

    #expect(transfer != nil)
    #expect(transfer?.hash == log.transactionHash)
    #expect(transfer?.uniqueId == "\(log.transactionHash):erc20:2")
    #expect(transfer?.from == "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    #expect(transfer?.to == "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
    #expect(transfer?.category == .erc20)
    #expect(transfer?.asset == "USDC")
    #expect(transfer?.rawContract.address == "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
    #expect(transfer?.rawContract.rawValue == log.data)
    #expect(transfer?.rawContract.decimalsValue == 6)
    #expect(transfer?.blockNum == log.blockNumber)
    #expect(transfer?.metadata.blockTimestamp == "2024-09-12T12:34:56.000Z")
  }

  @Test("erc20Transfer returns nil for a log with fewer than 3 topics")
  func erc20TransferReturnsNilForShortTopics() {
    let log = Self.usdcTransferLog(topics: [
      "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3e",
      "0x000000000000000000000000aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    ])

    let transfer = LogTransferMapper.erc20Transfer(
      from: log, decimals: 6, symbol: "USDC", timestamp: Date())

    #expect(transfer == nil)
  }
}

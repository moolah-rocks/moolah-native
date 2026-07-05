// MoolahTests/Shared/CryptoImport/AlchemyReceiptLogsDecodingTests.swift
import Foundation
import Testing

@testable import Moolah

/// Decoding coverage for `AlchemyTransactionReceipt.logs` / `ReceiptLog` —
/// split from `AlchemyTransactionReceiptDecodingTests` (gas-field coverage)
/// to keep each suite under the `type_body_length` threshold. Exercises the
/// receipt envelope through `LiveAlchemyClient`, matching the production
/// decode path.
@Suite("AlchemyTransactionReceipt logs decoding")
struct AlchemyReceiptLogsDecodingTests {
  @Test
  func receiptDecodesLogsWithParsedLogIndex() async throws {
    // Two distinct log entries — the wrap/unwrap detector reads
    // `address`/`topics`/`data`/`logIndex` off each to recognise WETH
    // `Deposit`/`Withdrawal` events.
    let payload = Data(
      """
      {
        "jsonrpc": "2.0",
        "id": 1,
        "result": {
          "gasUsed": "0x5208",
          "effectiveGasPrice": "0x59682f00",
          "from": "0x1111111111111111111111111111111111111111",
          "logs": [
            {
              "address": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
              "topics": [
                "0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c"
              ],
              "data": "0x0000000000000000000000000000000000000000000000000de0b6b3a7640000",
              "logIndex": "0x0"
            },
            {
              "address": "0xdac17f958d2ee523a2206206994597c13d831ec7",
              "topics": [
                "0x7fcf532c15f0a6db0bd6d0e038bea71d30d808c7d98cb3bf7268a95bf5081b65",
                "0x0000000000000000000000001111111111111111111111111111111111111111"
              ],
              "data": "0x0000000000000000000000000000000000000000000000000000000000000001",
              "logIndex": "0x1"
            }
          ]
        }
      }
      """.utf8)
    let client = AlchemyTestSupport.makeClient { request in
      (AlchemyTestSupport.okResponse(for: request), payload)
    }

    let receipt = try await client.getTransactionReceipt(
      chain: .ethereum, hash: "0xhaslogs")

    #expect(receipt.logs.count == 2)
    #expect(receipt.logs[0].address == "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2")
    #expect(receipt.logs[0].logIndex == 0)
    #expect(receipt.logs[1].address == "0xdac17f958d2ee523a2206206994597c13d831ec7")
    #expect(receipt.logs[1].logIndex == 1)
    #expect(receipt.logs[1].topics.count == 2)
  }

  @Test
  func missingLogsKeyDecodesToEmptyArray() async throws {
    // No `logs` key at all — a minimal wire shape must still decode
    // rather than fail, and `logs` maps to `[]`.
    let payload = Data(
      """
      {
        "jsonrpc": "2.0",
        "id": 1,
        "result": {
          "gasUsed": "0x5208",
          "effectiveGasPrice": "0x59682f00",
          "from": "0x1111111111111111111111111111111111111111"
        }
      }
      """.utf8)
    let client = AlchemyTestSupport.makeClient { request in
      (AlchemyTestSupport.okResponse(for: request), payload)
    }

    let receipt = try await client.getTransactionReceipt(
      chain: .ethereum, hash: "0xnologs")

    #expect(receipt.logs.isEmpty)
  }

  @Test
  func malformedLogIndexDropsOnlyThatLogEntry() async throws {
    // One well-formed log and one with an unparseable `logIndex` — the
    // lenient decoder drops only the bad entry rather than failing the
    // whole receipt (see the leniency rationale on
    // `AlchemyTransactionReceiptPayload.logs`).
    let payload = Data(
      """
      {
        "jsonrpc": "2.0",
        "id": 1,
        "result": {
          "gasUsed": "0x5208",
          "effectiveGasPrice": "0x59682f00",
          "from": "0x1111111111111111111111111111111111111111",
          "logs": [
            {
              "address": "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
              "topics": ["0xe1fffcc4923d04b559f4d29a8bfc6cda04eb5b0d3c460751c2402c5c5cc9109c"],
              "data": "0x00",
              "logIndex": "0xZZZ"
            },
            {
              "address": "0xdac17f958d2ee523a2206206994597c13d831ec7",
              "topics": ["0x7fcf532c15f0a6db0bd6d0e038bea71d30d808c7d98cb3bf7268a95bf5081b65"],
              "data": "0x01",
              "logIndex": "0x1"
            }
          ]
        }
      }
      """.utf8)
    let client = AlchemyTestSupport.makeClient { request in
      (AlchemyTestSupport.okResponse(for: request), payload)
    }

    let receipt = try await client.getTransactionReceipt(
      chain: .ethereum, hash: "0xbadlogindex")

    #expect(receipt.logs.count == 1)
    #expect(receipt.logs[0].logIndex == 1)
  }
}

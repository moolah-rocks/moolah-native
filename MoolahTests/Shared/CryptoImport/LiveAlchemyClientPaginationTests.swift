// MoolahTests/Shared/CryptoImport/LiveAlchemyClientPaginationTests.swift
import Foundation
import Testing

@testable import Moolah

/// `alchemy_getAssetTransfers` caps each response at 1000 transfers and
/// returns a `pageKey` when more remain. `getAssetTransfers` must follow
/// the `pageKey` until it is absent — otherwise wallets with heavy
/// (often spam-airdrop) inbound history silently truncate at the oldest
/// 1000 transfers per direction, producing wrong balances.
@Suite("LiveAlchemyClient — pagination")
struct LiveAlchemyClientPaginationTests {
  /// One Alchemy `result` page: a single synthetic transfer plus an
  /// optional `pageKey`. Distinct `uniqueId` per call so the test can
  /// count concatenated transfers across pages and directions.
  private static func pageJSON(uniqueId: String, pageKey: String?) -> Data {
    let pageKeyField = pageKey.map { ",\"pageKey\":\"\($0)\"" } ?? ""
    let json = """
      {
        "jsonrpc": "2.0",
        "id": 1,
        "result": {
          "transfers": [
            {
              "blockNum": "0x12d4f0a",
              "uniqueId": "\(uniqueId)",
              "hash": "0xabc123def456000000000000000000000000000000000000000000000000aaaa",
              "from": "0x1111111111111111111111111111111111111111",
              "to": "0x2222222222222222222222222222222222222222",
              "value": 0.05,
              "asset": "ETH",
              "category": "external",
              "rawContract": {
                "value": "0xb1a2bc2ec50000",
                "address": null,
                "decimal": "0x12"
              },
              "metadata": {
                "blockTimestamp": "2024-09-12T12:34:56.000Z"
              }
            }
          ]\(pageKeyField)
        }
      }
      """
    return Data(json.utf8)
  }

  @Test
  func followsPageKeyAcrossPagesAndBothDirectionsUntilAbsent() async throws {
    let calls = TestCallRecorder()
    let client = AlchemyTestSupport.makeClient { request in
      calls.record(request: request)
      let params = (calls.captured.last?["params"] as? [[String: Any]])?.first ?? [:]
      let direction = params["fromAddress"] != nil ? "from" : "to"
      let priorPageKey = params["pageKey"] as? String
      if priorPageKey == nil {
        // Page 1 of this direction → hand back a pageKey for page 2.
        return (
          AlchemyTestSupport.okResponse(for: request),
          Self.pageJSON(uniqueId: "\(direction):0", pageKey: "\(direction)-PAGE2")
        )
      }
      // Page 2 → no pageKey, pagination ends for this direction.
      return (
        AlchemyTestSupport.okResponse(for: request),
        Self.pageJSON(uniqueId: "\(direction):1", pageKey: nil)
      )
    }

    let transfers = try await client.getAssetTransfers(
      chain: .optimism, walletAddress: "0xWALLET", fromBlock: 0, toBlock: nil
    )

    // 2 pages × 2 directions = 4 concatenated transfers.
    #expect(transfers.count == 4)
    #expect(Set(transfers.map(\.uniqueId)) == ["from:0", "from:1", "to:0", "to:1"])

    let recorded = calls.captured
    #expect(recorded.count == 4)
    // The follow-up request in each direction must carry the page-1 pageKey.
    let pageKeys = recorded.compactMap {
      (($0["params"] as? [[String: Any]])?.first)?["pageKey"] as? String
    }
    #expect(Set(pageKeys) == ["from-PAGE2", "to-PAGE2"])
  }

  @Test
  func stopsWhenProviderRepeatsAPageKeyRatherThanLoopingForever() async throws {
    let calls = TestCallRecorder()
    let client = AlchemyTestSupport.makeClient { request in
      calls.record(request: request)
      let params = (calls.captured.last?["params"] as? [[String: Any]])?.first ?? [:]
      let direction = params["fromAddress"] != nil ? "from" : "to"
      // A misbehaving provider hands back the SAME pageKey every time.
      // Bounded at 4 pages so a non-terminating client fails the
      // assertion instead of hanging the suite.
      let key = direction == "from" ? "fromAddress" : "toAddress"
      let n = calls.captured.filter {
        ((($0["params"] as? [[String: Any]])?.first)?[key]) != nil
      }.count
      return (
        AlchemyTestSupport.okResponse(for: request),
        Self.pageJSON(uniqueId: "\(direction):\(n)", pageKey: n < 4 ? "LOOP" : nil)
      )
    }

    let transfers = try await client.getAssetTransfers(
      chain: .optimism, walletAddress: "0xWALLET", fromBlock: 0, toBlock: nil
    )

    // The client must stop the first time it is handed a pageKey it has
    // already requested: 2 requests per direction (initial + the repeat
    // that triggers the guard), 4 total — never the bounded 5/direction.
    #expect(calls.captured.count == 4)
    #expect(transfers.count == 4)
  }
}

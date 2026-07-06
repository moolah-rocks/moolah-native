// MoolahTests/Shared/CryptoImport/DirectRPCChainClientWindowTests.swift
import Foundation
import Testing

@testable import Moolah

/// Covers the windowed-scan seam `DirectRPCChainClient` adds on top of the
/// existing two-pass `eth_getLogs` discovery: `currentHead(chain:)` surfaces
/// the raw `eth_blockNumber` head, and `getAssetTransfers(...,toBlock:)`
/// bounds every `eth_getLogs` chunk to a caller-supplied upper block instead
/// of always resolving the live head. A future windowed sync runner relies on
/// the bounded call never issuing `eth_blockNumber` — that RPC round-trip
/// would otherwise defeat the whole point of a caller-supplied window. Uses
/// its own `URLProtocol` stub (rather than
/// `DirectRPCChainClientTests`' `DirectRPCURLProtocolStub`) so this suite's
/// shared static handler can't race that suite's under parallel execution;
/// `.serialized` guards against races within this suite's own tests.
@Suite("DirectRPCChainClientWindowTests", .serialized)
struct DirectRPCChainClientWindowTests {
  private func makeClient(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  ) -> DirectRPCChainClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [WindowURLProtocolStub.self]
    let session = URLSession(configuration: config)
    WindowURLProtocolStub.requestHandler = handler
    let rpc = LiveJSONRPCClient(
      endpoint: WindowFixtures.endpoint,
      session: session,
      rateLimiter: RateLimiter(permitsPerSecond: 1_000),
      sleeper: { _ in })
    return DirectRPCChainClient(rpc: rpc, metadata: TokenMetadataResolver(rpc: rpc))
  }

  @Test
  func currentHeadReturnsStubbedBlockNumber() async throws {
    let recorder = WindowRequestRecorder()
    let client = makeClient { request in
      WindowFixtures.respond(to: request, recorder: recorder, logs: "[]")
    }
    let head = try await client.currentHead(chain: .ethereum)
    #expect(head == 0x100)
  }

  @Test
  func boundedWindowNeverExceedsToBlockAndSkipsHeadDiscovery() async throws {
    let recorder = WindowRequestRecorder()
    let client = makeClient { request in
      WindowFixtures.respond(to: request, recorder: recorder, logs: "[]")
    }
    _ = try await client.getAssetTransfers(
      chain: .ethereum,
      walletAddress: WindowFixtures.wallet,
      fromBlock: 100,
      toBlock: 200)

    let toBlocks = recorder.getLogsToBlocks
    #expect(!toBlocks.isEmpty)
    for toBlock in toBlocks {
      let parsed = try #require(RPCHex.parseUInt64(toBlock))
      #expect(parsed <= 200)
    }
    #expect(toBlocks.allSatisfy { $0 == "0xc8" })

    #expect(recorder.blockNumberCallCount == 0)
  }

  @Test
  func nilToBlockScansToStubbedHead() async throws {
    let recorder = WindowRequestRecorder()
    let client = makeClient { request in
      WindowFixtures.respond(to: request, recorder: recorder, logs: "[]")
    }
    _ = try await client.getAssetTransfers(
      chain: .ethereum,
      walletAddress: WindowFixtures.wallet,
      fromBlock: 100,
      toBlock: nil)

    let toBlocks = recorder.getLogsToBlocks
    #expect(!toBlocks.isEmpty)
    #expect(toBlocks.allSatisfy { $0 == "0x100" })

    #expect(recorder.blockNumberCallCount >= 1)
  }
}

/// Records every `eth_getLogs` filter's `toBlock` and how many times
/// `eth_blockNumber` was invoked, across concurrent outbound/inbound passes.
/// The recording call happens synchronously inside `URLProtocol.startLoading`
/// (never on the main actor, but always synchronous top-to-bottom per
/// request), so a plain `NSLock` — matching the rest of the suite's stub
/// conventions (e.g. `RecordingAlchemyClientStub`) — is enough; no actor
/// hop is needed and using one here would race the synchronous handler
/// against the test's later synchronous read.
final class WindowRequestRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var _getLogsToBlocks: [String] = []
  private var _blockNumberCallCount = 0

  var getLogsToBlocks: [String] {
    lock.withLock { _getLogsToBlocks }
  }

  var blockNumberCallCount: Int {
    lock.withLock { _blockNumberCallCount }
  }

  func recordGetLogs(toBlock: String) {
    lock.withLock { _getLogsToBlocks.append(toBlock) }
  }

  func recordBlockNumberCall() {
    lock.withLock { _blockNumberCallCount += 1 }
  }
}

/// Fixtures and dispatcher for the windowed-scan tests. Every `eth_getLogs`
/// response is the caller-supplied `logs` (empty by default — these tests
/// only care about the requested block range, not the discovered transfers),
/// so no block-timestamp or token-metadata round-trip is ever needed.
enum WindowFixtures {
  static let endpoint = URL(string: "https://rpc.window.example.test")!
  static let wallet = "0x1111111111111111111111111111111111111111"

  static func respond(
    to request: URLRequest,
    recorder: WindowRequestRecorder,
    logs: String
  ) -> (HTTPURLResponse, Data) {
    let ok = AlchemyTestSupport.okResponse(for: request)
    guard let object = AlchemyTestSupport.jsonRPCBodyObject(request) as? [String: Any],
      let method = object["method"] as? String
    else { return (ok, envelope("null")) }
    switch method {
    case "eth_blockNumber":
      recorder.recordBlockNumberCall()
      return (ok, envelope("\"0x100\""))
    case "eth_getLogs":
      let params = object["params"] as? [Any]
      let filter = params?.first as? [String: Any]
      if let toBlock = filter?["toBlock"] as? String {
        recorder.recordGetLogs(toBlock: toBlock)
      }
      return (ok, envelope(logs))
    default:
      return (ok, envelope("null"))
    }
  }

  private static func envelope(_ result: String) -> Data {
    Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(result)}".utf8)
  }
}

/// `URLProtocol` stub dedicated to this suite, with its own static handler
/// state so it cannot race `DirectRPCChainClientTests`' stub under parallel
/// suite execution. `nonisolated(unsafe)` is safe because the enclosing
/// `@Suite` is `.serialized`, so tests within it never run concurrently: the
/// handler is assigned before any stub invocation. Body decoding is delegated
/// to the shared `AlchemyTestSupport.jsonRPCBodyObject`.
final class WindowURLProtocolStub: URLProtocol {
  nonisolated(unsafe) static var requestHandler:
    (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = WindowURLProtocolStub.requestHandler else {
      client?.urlProtocol(self, didFailWithError: URLError(.unknown))
      return
    }
    do {
      let (response, data) = try handler(request)
      client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: data)
      client?.urlProtocolDidFinishLoading(self)
    } catch {
      client?.urlProtocol(self, didFailWithError: error)
    }
  }

  override func stopLoading() {}
}

// MoolahTests/Shared/CryptoImport/DirectRPCChainClientTests.swift
import Foundation
import Testing

@testable import Moolah

/// Covers `DirectRPCChainClient`'s two-pass `eth_getLogs` ERC-20 discovery:
/// the outbound/inbound topic passes, de-duplication of a self-send that
/// matches both passes, the wrapped-native mint/burn guard, and the mapping
/// of surviving logs into `AlchemyTransfer` rows with block timestamps and
/// per-contract metadata resolved. The suite is `.serialized` because it
/// drives a shared `URLProtocol` stub.
@Suite("DirectRPCChainClient", .serialized)
struct DirectRPCChainClientTests {
  private func makeClient(
    handler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)
  ) -> DirectRPCChainClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [DirectRPCURLProtocolStub.self]
    let session = URLSession(configuration: config)
    DirectRPCURLProtocolStub.requestHandler = handler
    let rpc = LiveJSONRPCClient(
      endpoint: DirectRPCFixtures.endpoint,
      session: session,
      rateLimiter: RateLimiter(permitsPerSecond: 1_000),
      sleeper: { _ in })
    return DirectRPCChainClient(rpc: rpc, metadata: TokenMetadataResolver(rpc: rpc))
  }

  @Test
  func discoversInboundOutboundAndDeduplicatesSelfSend() async throws {
    let client = makeClient { request in
      DirectRPCFixtures.respond(
        to: request,
        outboundLogs: DirectRPCFixtures.outboundUSDCLogs,
        inboundLogs: DirectRPCFixtures.inboundUSDCLogs)
    }
    let transfers = try await client.getAssetTransfers(
      chain: .ethereum,
      walletAddress: DirectRPCFixtures.wallet,
      fromBlock: 0)

    // Two distinct transfers plus one self-send counted once.
    #expect(transfers.count == 3)
    #expect(transfers.filter { $0.hash == "0xselfsend" }.count == 1)

    let outbound = try #require(transfers.first { $0.hash == "0xoutbound" })
    #expect(outbound.from == DirectRPCFixtures.wallet)
    #expect(outbound.to == DirectRPCFixtures.counterparty)
    #expect(outbound.category == .erc20)
    #expect(outbound.asset == "USDC")
    #expect(outbound.rawContract.rawValue == "0x0f4240")
    #expect(outbound.rawContract.decimalsValue == 6)

    let inbound = try #require(transfers.first { $0.hash == "0xinbound" })
    #expect(inbound.from == DirectRPCFixtures.counterparty)
    #expect(inbound.to == DirectRPCFixtures.wallet)
    #expect(inbound.rawContract.rawValue == "0x1e8480")
  }

  @Test
  func skipsWrappedNativeMintLog() async throws {
    let client = makeClient { request in
      DirectRPCFixtures.respond(
        to: request,
        outboundLogs: "[]",
        inboundLogs: DirectRPCFixtures.inboundWETHMintLogs)
    }
    let transfers = try await client.getAssetTransfers(
      chain: .ethereum,
      walletAddress: DirectRPCFixtures.wallet,
      fromBlock: 0)
    #expect(transfers.isEmpty)
  }

  @Test
  func mapsReceiptGasFields() async throws {
    let client = makeClient { request in
      (
        AlchemyTestSupport.okResponse(for: request),
        Data(
          """
          {"jsonrpc":"2.0","id":1,"result":{
            "transactionHash":"0xabc",
            "from":"0xAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "gasUsed":"0x5208","effectiveGasPrice":"0x3b9aca00","logs":[]
          }}
          """.utf8)
      )
    }
    let receipt = try await client.getTransactionReceipt(chain: .ethereum, hash: "0xabc")
    #expect(receipt.hash == "0xabc")
    #expect(receipt.gasUsed == Decimal(21_000))
    #expect(receipt.effectiveGasPrice == Decimal(1_000_000_000))
    #expect(receipt.from == "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    #expect(receipt.l1FeeWei == nil)
  }
}

/// Fixtures and the shared response dispatcher for the direct-RPC discovery
/// tests. The dispatcher inspects each request's JSON-RPC method (and, for
/// `eth_getLogs`, which topic slot carries the wallet) so one handler can
/// script an entire discovery round-trip: `eth_blockNumber`, both
/// `eth_getLogs` passes, the batched `eth_getBlockByNumber` timestamp
/// lookup, and the `decimals()`/`symbol()` `eth_call`s.
enum DirectRPCFixtures {
  static let endpoint = URL(string: "https://rpc.example.test")!
  static let wallet = "0x1111111111111111111111111111111111111111"
  static let counterparty = "0x2222222222222222222222222222222222222222"

  private static let walletTopic = RPCHex.addressTopic(wallet)
  private static let counterpartyTopic = RPCHex.addressTopic(counterparty)
  private static let zeroTopic = RPCHex.addressTopic(DirectRPCConstants.zeroAddress)
  private static let usdc = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
  private static let weth = "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"
  private static let transferTopic = DirectRPCConstants.transferTopic
  private static let decimalsSelector = "0x313ce567"
  private static let symbolSelector = "0x95d89b41"

  /// `decimals()` → 6, as a 32-byte ABI word.
  private static let usdcDecimalsHex =
    "0x0000000000000000000000000000000000000000000000000000000000000006"
  /// `symbol()` → "USDC" in the dynamic ABI `string` layout (offset,
  /// length, then the right-zero-padded UTF-8 bytes).
  private static let usdcSymbolHex =
    "0x0000000000000000000000000000000000000000000000000000000000000020"
    + "0000000000000000000000000000000000000000000000000000000000000004"
    + "5553444300000000000000000000000000000000000000000000000000000000"

  /// Outbound pass (wallet as `from`): a real outbound USDC transfer plus a
  /// self-send that also appears in the inbound pass.
  static let outboundUSDCLogs = """
    [
      \(log(LogSpec(
        address: usdc, from: walletTopic, to: counterpartyTopic,
        data: "0x0f4240", block: "0x20", hash: "0xoutbound", index: "0x0"))),
      \(selfSendLog)
    ]
    """

  /// Inbound pass (wallet as `to`): a real inbound USDC transfer plus the
  /// same self-send, which must be de-duplicated against the outbound copy.
  static let inboundUSDCLogs = """
    [
      \(log(LogSpec(
        address: usdc, from: counterpartyTopic, to: walletTopic,
        data: "0x1e8480", block: "0x10", hash: "0xinbound", index: "0x0"))),
      \(selfSendLog)
    ]
    """

  /// A WETH mint (`from == 0x0`) delivered to the wallet — dropped by the
  /// wrapped-native guard rather than mapped.
  static let inboundWETHMintLogs = """
    [
      \(log(LogSpec(
        address: weth, from: zeroTopic, to: walletTopic,
        data: "0xde0b6b3a7640000", block: "0x10", hash: "0xwethmint", index: "0x0")))
    ]
    """

  private static let selfSendLog = log(
    LogSpec(
      address: usdc, from: walletTopic, to: walletTopic,
      data: "0x64", block: "0x10", hash: "0xselfsend", index: "0x2"))

  /// One ERC-20 `Transfer` log's mutable fields, bundled so the JSON builder
  /// takes a single value rather than seven positional arguments.
  private struct LogSpec {
    let address: String
    let from: String
    let to: String
    let data: String
    let block: String
    let hash: String
    let index: String
  }

  private static func log(_ spec: LogSpec) -> String {
    """
    {"address":"\(spec.address)","topics":["\(transferTopic)","\(spec.from)","\(spec.to)"],
     "data":"\(spec.data)","blockNumber":"\(spec.block)",
     "transactionHash":"\(spec.hash)","logIndex":"\(spec.index)"}
    """
  }

  /// Dispatches one request to its scripted response. `outboundLogs` /
  /// `inboundLogs` are JSON-array result bodies for the two `eth_getLogs`
  /// passes, distinguished by which topic slot holds the wallet.
  static func respond(
    to request: URLRequest,
    outboundLogs: String,
    inboundLogs: String
  ) -> (HTTPURLResponse, Data) {
    let ok = AlchemyTestSupport.okResponse(for: request)
    let body = DirectRPCURLProtocolStub.bodyObject(request)
    if let batch = body as? [[String: Any]] {
      let items = batch.map { item -> String in
        let id = item["id"] as? Int ?? 1
        return "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"result\":{\"timestamp\":\"0x60\"}}"
      }
      return (ok, Data("[\(items.joined(separator: ","))]".utf8))
    }
    guard let object = body as? [String: Any],
      let method = object["method"] as? String
    else { return (ok, envelope("null")) }
    let params = object["params"] as? [Any]
    switch method {
    case "eth_blockNumber":
      return (ok, envelope("\"0x100\""))
    case "eth_getLogs":
      let filter = params?.first as? [String: Any]
      let topics = filter?["topics"] as? [Any]
      let slot1 = (topics?.count ?? 0) > 1 ? topics?[1] as? String : nil
      let outbound = slot1 == walletTopic
      return (ok, envelope(outbound ? outboundLogs : inboundLogs))
    case "eth_call":
      let callObject = params?.first as? [String: Any]
      let selector = callObject?["data"] as? String
      let result = selector == decimalsSelector ? usdcDecimalsHex : usdcSymbolHex
      return (ok, envelope("\"\(result)\""))
    default:
      return (ok, envelope("null"))
    }
  }

  private static func envelope(_ result: String) -> Data {
    Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(result)}".utf8)
  }
}

/// `URLProtocol` stub for the direct-RPC discovery tests, with its own static
/// state so it cannot race another suite's stub under parallel execution.
/// `nonisolated(unsafe)` is safe because the enclosing `@Suite` is
/// `.serialized`.
final class DirectRPCURLProtocolStub: URLProtocol {
  nonisolated(unsafe) static var requestHandler:
    (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

  /// Decodes the request's JSON body — streamed (URLSession converts
  /// `httpBody` to a stream for a custom `URLProtocol`) or in-memory — into a
  /// Foundation object the dispatcher can branch on.
  static func bodyObject(_ request: URLRequest) -> Any? {
    let data: Data
    if let stream = request.httpBodyStream {
      data = readStream(stream)
    } else if let body = request.httpBody {
      data = body
    } else {
      return nil
    }
    return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = DirectRPCURLProtocolStub.requestHandler else {
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

  private static func readStream(_ stream: InputStream) -> Data {
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 1024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
      let read = stream.read(buffer, maxLength: bufferSize)
      if read <= 0 { break }
      data.append(buffer, count: read)
    }
    return data
  }
}

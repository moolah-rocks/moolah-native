// MoolahTests/Shared/CryptoImport/RoutingChainDataClientTests.swift
import Foundation
import Testing

@testable import Moolah

/// Covers `RoutingChainDataClient`'s dispatch: each on-chain call is routed
/// through a real `RPCEndpointResolver` and handed to the Alchemy client or a
/// direct client per the resolved precedence. A chain with a matching custom
/// endpoint goes direct; a chain with no custom match but a present Alchemy
/// key goes to Alchemy; and both `getAssetTransfers` and `getTransactionReceipt`
/// for the same chain reuse one concrete resolved client (one metadata cache).
@Suite("RoutingChainDataClient", .serialized)
struct RoutingChainDataClientTests {
  private static let customEndpoint = "https://op.custom.test"
  private static let wallet = "0x1111111111111111111111111111111111111111"

  /// Scripts `eth_chainId` per endpoint URL: `op.custom.test` → chain 10
  /// (OP Mainnet), Ethereum's default publicnode URL → chain 1. Any other
  /// URL is a test-authoring mistake — HTTP 404 makes that loud.
  private func chainIdHandler(_ request: URLRequest) -> (HTTPURLResponse, Data) {
    switch request.url?.absoluteString {
    case Self.customEndpoint:
      return (
        AlchemyTestSupport.okResponse(for: request),
        Data(#"{"jsonrpc":"2.0","id":1,"result":"0xa"}"#.utf8)
      )
    case ChainConfig.ethereum.defaultRPCURL.absoluteString:
      return (
        AlchemyTestSupport.okResponse(for: request),
        Data(#"{"jsonrpc":"2.0","id":1,"result":"0x1"}"#.utf8)
      )
    default:
      return (AlchemyTestSupport.response(for: request, statusCode: 404), Data())
    }
  }

  /// The routing client under test plus the recording stubs and factory
  /// counter a test inspects to assert dispatch and memoization.
  private struct Harness {
    let routing: RoutingChainDataClient
    let alchemyStub: RecordingChainDataClient
    let directStub: RecordingChainDataClient
    let directFactoryCalls: CallCounter
  }

  /// Builds the harness: a real `RPCEndpointResolver` probing over a
  /// URLProtocol stub, plus recording Alchemy/direct stubs the routing client
  /// dispatches to. `directFactoryCalls` counts `makeDirect` invocations so a
  /// test can prove the wrapping client is memoized per chain.
  private func makeHarness(
    alchemyKeyPresent: @escaping @Sendable () -> Bool
  ) -> Harness {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [RoutingURLProtocolStub.self]
    let session = URLSession(configuration: config)
    RoutingURLProtocolStub.requestHandler = { [self] request in chainIdHandler(request) }

    let resolver = RPCEndpointResolver(
      customEndpoints: [Self.customEndpoint],
      alchemyKeyPresent: alchemyKeyPresent,
      makeRPC: { url in
        LiveJSONRPCClient(
          endpoint: url,
          session: session,
          rateLimiter: RateLimiter(permitsPerSecond: 1_000),
          sleeper: { _ in })
      })

    let alchemyStub = RecordingChainDataClient(label: "alchemy")
    let directStub = RecordingChainDataClient(label: "direct")
    let directFactoryCalls = CallCounter()
    let routing = RoutingChainDataClient(
      resolver: resolver,
      makeAlchemy: { alchemyStub },
      makeDirect: { _ in
        directFactoryCalls.increment()
        return directStub
      })
    return Harness(
      routing: routing,
      alchemyStub: alchemyStub,
      directStub: directStub,
      directFactoryCalls: directFactoryCalls)
  }

  @Test
  func nonMatchingChainWithAlchemyKeyDispatchesToAlchemy() async throws {
    let harness = makeHarness(alchemyKeyPresent: { true })

    _ = try await harness.routing.getAssetTransfers(
      chain: .ethereum, walletAddress: Self.wallet, fromBlock: 0)

    #expect(harness.alchemyStub.transferChains == [1])
    #expect(harness.directStub.transferChains.isEmpty)
  }

  @Test
  func matchingCustomEndpointDispatchesToDirect() async throws {
    let harness = makeHarness(alchemyKeyPresent: { true })

    _ = try await harness.routing.getAssetTransfers(
      chain: .optimism, walletAddress: Self.wallet, fromBlock: 0)

    #expect(harness.directStub.transferChains == [10])
    #expect(harness.alchemyStub.transferChains.isEmpty)
  }

  @Test
  func receiptsFollowTheSameRoutingAsTransfers() async throws {
    let harness = makeHarness(alchemyKeyPresent: { true })

    _ = try await harness.routing.getTransactionReceipt(chain: .ethereum, hash: "0xabc")
    _ = try await harness.routing.getTransactionReceipt(chain: .optimism, hash: "0xdef")

    #expect(harness.alchemyStub.receiptChains == [1])
    #expect(harness.directStub.receiptChains == [10])
  }

  @Test
  func resolvedClientIsMemoizedAcrossTransferAndReceiptForSameChain() async throws {
    let harness = makeHarness(alchemyKeyPresent: { true })

    _ = try await harness.routing.getAssetTransfers(
      chain: .optimism, walletAddress: Self.wallet, fromBlock: 0)
    _ = try await harness.routing.getTransactionReceipt(chain: .optimism, hash: "0xdef")

    // One `makeDirect` call for both the transfer and the receipt pass on the
    // same chain — the wrapping client (and its metadata cache) is reused.
    #expect(harness.directFactoryCalls.value == 1)
    #expect(harness.directStub.transferChains == [10])
    #expect(harness.directStub.receiptChains == [10])
  }

  @Test
  func invalidateReResolvesAgainstTheNewEndpointList() async throws {
    // Alchemy key present; OP Mainnet starts routed to the custom endpoint.
    let harness = makeHarness(alchemyKeyPresent: { true })

    _ = try await harness.routing.getAssetTransfers(
      chain: .optimism, walletAddress: Self.wallet, fromBlock: 0)
    _ = try await harness.routing.getTransactionReceipt(chain: .optimism, hash: "0xabc")
    #expect(harness.directStub.transferChains == [10])
    #expect(harness.directStub.receiptChains == [10])
    #expect(harness.alchemyStub.transferChains.isEmpty)

    // Drop the custom endpoint. With the Alchemy key still present, OP now
    // resolves to Alchemy — and the memoized direct client must be dropped so
    // the next call re-resolves rather than reusing it.
    await harness.routing.invalidate(customEndpoints: [])

    _ = try await harness.routing.getAssetTransfers(
      chain: .optimism, walletAddress: Self.wallet, fromBlock: 0)
    _ = try await harness.routing.getTransactionReceipt(chain: .optimism, hash: "0xdef")

    // Post-invalidate calls dispatched to Alchemy; the direct stub saw no new
    // calls beyond the pre-invalidate ones.
    #expect(harness.alchemyStub.transferChains == [10])
    #expect(harness.alchemyStub.receiptChains == [10])
    #expect(harness.directStub.transferChains == [10])
    #expect(harness.directStub.receiptChains == [10])
  }
}

/// Records which chains each `ChainDataClient` method was invoked for so a
/// routing test can assert the dispatch target. Reference type (the routing
/// client hands back a shared instance from the factory closures); lock-guarded
/// to satisfy `Sendable`.
private final class RecordingChainDataClient: @unchecked Sendable {
  let label: String
  private let lock = NSLock()
  private var transfers: [Int] = []
  private var receipts: [Int] = []

  init(label: String) { self.label = label }

  var transferChains: [Int] {
    lock.lock()
    defer { lock.unlock() }
    return transfers
  }

  var receiptChains: [Int] {
    lock.lock()
    defer { lock.unlock() }
    return receipts
  }

  /// Synchronous mutators so the lock is never taken from an `async` frame
  /// (`NSLock.lock()` is unavailable there).
  private func recordTransfer(_ chainId: Int) {
    lock.lock()
    defer { lock.unlock() }
    transfers.append(chainId)
  }

  private func recordReceipt(_ chainId: Int) {
    lock.lock()
    defer { lock.unlock() }
    receipts.append(chainId)
  }
}

// MARK: - ChainDataClient

extension RecordingChainDataClient: ChainDataClient {
  func getAssetTransfers(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64
  ) async throws -> [AlchemyTransfer] {
    recordTransfer(chain.chainId)
    return []
  }

  func getTransactionReceipt(
    chain: ChainConfig,
    hash: String
  ) async throws -> AlchemyTransactionReceipt {
    recordReceipt(chain.chainId)
    return AlchemyTransactionReceipt(
      hash: hash, gasUsed: 0, effectiveGasPrice: 0, from: "0x", l1FeeWei: nil, logs: [])
  }
}

/// Thread-safe invocation counter for the `makeDirect` factory closure.
private final class CallCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  func increment() {
    lock.lock()
    defer { lock.unlock() }
    count += 1
  }

  var value: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }
}

/// Dedicated `URLProtocol` stub for the `RoutingChainDataClient` suite, with
/// its own static handler state so it cannot race other suites' stubs when
/// Swift Testing runs suites in parallel. `nonisolated(unsafe)` is safe because
/// the enclosing `@Suite` is `.serialized`, so tests within it never run
/// concurrently: the handler is assigned before any stub invocation.
private final class RoutingURLProtocolStub: URLProtocol {
  nonisolated(unsafe) static var requestHandler:
    (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

  override static func canInit(with request: URLRequest) -> Bool { true }
  override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let handler = RoutingURLProtocolStub.requestHandler else {
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

// MoolahTests/Shared/CryptoImport/DiscoveryCancellationIsolationTests.swift

import Foundation
import Testing

@testable import Moolah

/// Pins the design's discovery-cancellation isolation invariant: when a
/// `ProfileSession` tears down, the in-flight discovery `Task` it
/// initiated for `(chainId, contractAddress)` must NOT be cancelled —
/// because that same task is the coalesced future every other session
/// awaiting the same key is already attached to.
///
/// `CryptoTokenDiscoveryService.inFlight` is owned by the actor itself
/// (not by any per-session task array), so cancelling the originating
/// caller's `await` is structurally insulated from the actor-owned
/// `Task<CryptoRegistration, Error>`. This test makes that contract
/// observable: cancel session A's coroutine while session B is still
/// awaiting the same key, then verify session B completes normally.
@Suite("Discovery cancellation isolation across sessions")
struct DiscoveryCancellationIsolationTests {

  /// Resolver that suspends every call on a continuation and only
  /// returns when the test calls `release()`. Lets the test prove the
  /// in-flight task survived a sibling caller's cancellation.
  private actor BlockingRegistrationResolver: CryptoRegistrationResolver {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var resolverCalls = 0

    func release() {
      let waiters = continuations
      continuations = []
      for cont in waiters { cont.resume() }
    }

    func callCount() -> Int { resolverCalls }

    func resolveRegistration(
      chainId: Int,
      contractAddress: String?,
      symbol: String?,
      isNative: Bool
    ) async throws -> CryptoRegistration {
      resolverCalls += 1
      await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        continuations.append(cont)
      }
      let resolvedSymbol = symbol ?? "TKN"
      let instrument = Instrument.crypto(
        chainId: chainId,
        contractAddress: isNative ? nil : contractAddress,
        symbol: resolvedSymbol,
        name: resolvedSymbol,
        decimals: 18)
      return CryptoRegistration(
        instrument: instrument,
        mapping: CryptoProviderMapping(
          instrumentId: instrument.id,
          coingeckoId: "test-id",
          cryptocompareSymbol: nil,
          binanceSymbol: nil))
    }
  }

  @Test("Cancelling session A's await does not cancel the in-flight task session B is on")
  func sessionACancelDoesNotPropagateToSessionB() async throws {
    let registry = StubInstrumentRegistry()
    let resolver = BlockingRegistrationResolver()
    let service = CryptoTokenDiscoveryService(
      registry: registry, resolver: resolver)

    let chain = ChainConfig.ethereum
    let contract = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"

    // Session B starts first so its await is already attached when we
    // launch session A. Use a continuation to handshake on "B is in".
    let bResult = Task<CryptoRegistration, Error> {
      try await service.resolveOrLoad(
        chain: chain, contractAddress: contract,
        symbol: "USDC", name: "USD Coin", decimals: 6)
    }

    // Session A piggy-backs on the same in-flight task. The actor's
    // serial executor guarantees A sees the task B installed in
    // `inFlight`. Both calls are coalesced — `resolveRegistration`
    // runs at most once.
    let aResult = Task<CryptoRegistration, Error> {
      try await service.resolveOrLoad(
        chain: chain, contractAddress: contract,
        symbol: "USDC", name: "USD Coin", decimals: 6)
    }

    // Wait for the resolver to be entered before cancelling. Once
    // `callCount` is 1 we know the actor's underlying task is running
    // inside `resolveRegistration`'s `await withCheckedContinuation`.
    // Bounded by a `ContinuousClock`-deadline backstop so a regression
    // (resolver never enters) fails the test fast instead of hanging.
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        while await resolver.callCount() == 0 {
          await Task.yield()
        }
      }
      group.addTask {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        try await ContinuousClock().sleep(until: deadline)
        Issue.record(
          "Resolver was never entered — discovery actor coalescing may be broken")
      }
      try await group.next()
      group.cancelAll()
    }

    // Tear down "session A" — cancelling its coroutine simulates the
    // session being released while a discovery is mid-flight. The
    // actor's in-flight task must NOT inherit the cancellation.
    aResult.cancel()

    // Release the resolver. Session B's `await` must complete with the
    // resolved registration; session A's cancelled task either throws
    // CancellationError or also returns successfully (the design
    // doesn't promise either way for cancelled callers — only that B
    // is unaffected).
    await resolver.release()

    let registration = try await bResult.value
    #expect(registration.instrument.ticker == "USDC")
    #expect(await resolver.callCount() == 1, "resolver must run exactly once for coalesced callers")
  }
}

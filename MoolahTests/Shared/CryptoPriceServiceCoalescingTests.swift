import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the in-flight coalescing of `CryptoPriceService.price(...)`:
/// concurrent requests for the same token that all miss the cache share a
/// single provider fetch instead of each hitting the network.
@Suite("CryptoPriceService coalescing")
struct CryptoPriceServiceCoalescingTests {
  private let ethInstrument = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
  )

  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  @Test("Concurrent same-token requests share one fetch")
  func concurrentRequestsCoalesceIntoOneFetch() async throws {
    let frozen = try date("2024-02-01")
    let utc = try #require(TimeZone(identifier: "UTC"))
    let client = GatedCryptoPriceClient(prices: ["1:native": ["2024-01-20": dec("12")]])
    let database = try ProfileIndexDatabase.openInMemory()
    let service = CryptoPriceService(
      clients: [client], database: database, resolutionClient: nil,
      now: { frozen }, timeZone: utc)

    // First request enters the provider and parks on the gate.
    let first = Task {
      try await service.price(
        for: ethInstrument, mapping: ethMapping, on: try date("2024-01-20"))
    }
    await client.awaitFirstFetch()

    // Second request for the same token+date arrives while the first fetch is
    // still in flight; it should await the shared task, not start its own.
    let second = Task {
      try await service.price(
        for: ethInstrument, mapping: ethMapping, on: try date("2024-01-20"))
    }
    // `second` coalesces as long as it runs before `openGate()`: the owner's
    // in-flight entry persists for as long as its (gated) fetch is in flight,
    // so `second` deterministically observes it on its `extensionTasks` check.
    // The only requirement is that `second` is scheduled at all — these yields
    // are a large margin over the handful of actor hops it needs to get there.
    for _ in 0..<200 { await Task.yield() }

    await client.openGate()
    let firstPrice = try await first.value
    let secondPrice = try await second.value

    #expect(firstPrice == dec("12"))
    #expect(secondPrice == dec("12"))
    #expect(await client.fetchCount == 1)
  }

  @Test("Sequential requests after a fill do not refetch")
  func sequentialRequestAfterFillUsesCache() async throws {
    let frozen = try date("2024-02-01")
    let utc = try #require(TimeZone(identifier: "UTC"))
    let client = GatedCryptoPriceClient(prices: ["1:native": ["2024-01-20": dec("12")]])
    await client.openGate()  // no gating for this case
    let database = try ProfileIndexDatabase.openInMemory()
    let service = CryptoPriceService(
      clients: [client], database: database, resolutionClient: nil,
      now: { frozen }, timeZone: utc)

    let firstPrice = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: try date("2024-01-20"))
    let secondPrice = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: try date("2024-01-20"))

    #expect(firstPrice == dec("12"))
    #expect(secondPrice == dec("12"))
    #expect(await client.fetchCount == 1)
  }
}

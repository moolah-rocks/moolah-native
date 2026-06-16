// MoolahTests/Shared/CryptoPriceServiceTestsMore.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("CryptoPriceService — Part 2")
struct CryptoPriceServiceTestsMore {
  private let ethInstrument = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
  )

  private let btcInstrument = Instrument.crypto(
    chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8
  )
  private let btcMapping = CryptoProviderMapping(
    instrumentId: "0:native", coingeckoId: "bitcoin",
    cryptocompareSymbol: "BTC", binanceSymbol: "BTCUSDT"
  )

  private var ethRegistration: CryptoRegistration {
    CryptoRegistration(instrument: ethInstrument, mapping: ethMapping)
  }
  private var btcRegistration: CryptoRegistration {
    CryptoRegistration(instrument: btcInstrument, mapping: btcMapping)
  }

  private func makeService(
    clients: [CryptoPriceClient] = [],
    prices: [String: [String: Decimal]] = [:],
    shouldFail: Bool = false,
    database: DatabaseQueue? = nil,
    resolutionClient: (any TokenResolutionClient)? = nil,
    now: @Sendable @escaping () -> Date = { Date() }
  ) throws -> CryptoPriceService {
    let clientList =
      clients.isEmpty
      ? [FixedCryptoPriceClient(prices: prices, shouldFail: shouldFail)]
      : clients
    let resolved = try database ?? ProfileIndexDatabase.openInMemory()
    return CryptoPriceService(
      clients: clientList,
      database: resolved,
      resolutionClient: resolutionClient,
      now: now
    )
  }

  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    guard let result = formatter.date(from: string) else {
      fatalError("Could not parse ISO8601 full-date string: \(string)")
    }
    return result
  }

  // SQL round-trip + rollback + persistence-efficiency tests live in
  // `CryptoPriceServicePersistenceTests`.

  // MARK: - Prefetch

  @Test
  func prefetchUpdatesCacheForRegisteredItems() async throws {
    // Pin `now` to 2026-04-12 so `prefetchLatest` tags the live tick as
    // yesterday (2026-04-11), making `price(on: 2026-04-11)` a cache hit
    // rather than a bounded backward-extension fetch. The bounded loop
    // (introduced in the contiguous-extension fix) makes no progress when
    // the client only knows 2026-04-11 but the current bounds start at
    // 2026-06-16 (today's yesterday with wall-clock `now`) — so the test
    // must pin `now` to align the prefetch date with the requested date.
    let frozen = date("2026-04-12")
    let service = try makeService(
      prices: [
        "1:native": ["2026-04-11": dec("1640.00")],
        "0:native": ["2026-04-11": dec("67890.00")],
      ],
      now: { frozen }
    )
    await service.prefetchLatest(for: [ethRegistration, btcRegistration])
    let ethPrice = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-04-11"))
    #expect(ethPrice == dec("1640.00"))
  }

  // MARK: - Multiple tokens cached independently

  @Test
  func differentTokensAreCachedIndependently() async throws {
    let service = try makeService(prices: [
      "1:native": ["2026-04-10": dec("1623.45")],
      "0:native": ["2026-04-10": dec("67890.00")],
    ])
    let ethPrice = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: date("2026-04-10"))
    let btcPrice = try await service.price(
      for: btcInstrument, mapping: btcMapping, on: date("2026-04-10"))
    #expect(ethPrice == dec("1623.45"))
    #expect(btcPrice == dec("67890.00"))
  }

  // MARK: - Token resolution

  @Test
  func resolveRegistration_populatesProviderFields() async throws {
    let result = TokenResolutionResult(
      coingeckoId: "uniswap",
      cryptocompareSymbol: "UNI",
      binanceSymbol: "UNIUSDT",
      resolvedName: "Uniswap",
      resolvedSymbol: "UNI",
      resolvedDecimals: 18
    )
    let service = try makeService(resolutionClient: FixedTokenResolutionClient(result: result))

    let registration = try await service.resolveRegistration(
      chainId: 1,
      contractAddress: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
      symbol: nil,
      isNative: false
    )
    #expect(registration.mapping.coingeckoId == "uniswap")
    #expect(registration.mapping.cryptocompareSymbol == "UNI")
    #expect(registration.mapping.binanceSymbol == "UNIUSDT")
    #expect(registration.instrument.name == "Uniswap")
  }

  @Test
  func resolveRegistration_noProvidersMatch_returnsPartialRegistration() async throws {
    let service = try makeService(
      resolutionClient: FixedTokenResolutionClient(result: TokenResolutionResult())
    )
    let registration = try await service.resolveRegistration(
      chainId: 999,
      contractAddress: "0xunknown",
      symbol: "UNKNOWN",
      isNative: false
    )
    #expect(registration.mapping.coingeckoId == nil)
    #expect(registration.mapping.cryptocompareSymbol == nil)
    #expect(registration.mapping.binanceSymbol == nil)
    #expect(registration.instrument.ticker == "UNKNOWN")
  }

  @Test
  func resolveRegistration_resolutionFails_throws() async throws {
    let service = try makeService(
      resolutionClient: FixedTokenResolutionClient(shouldFail: true)
    )
    await #expect(throws: (any Error).self) {
      try await service.resolveRegistration(
        chainId: 1, contractAddress: "0xabc", symbol: nil, isNative: false
      )
    }
  }
}

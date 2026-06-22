// MoolahTests/Shared/CryptoPriceServiceMetadataTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("CryptoPriceService — metadata self-resolution")
struct CryptoPriceServiceMetadataTests {
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  private let weth = Instrument.crypto(
    chainId: 1, contractAddress: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
    symbol: "WETH", name: "Wrapped Ether", decimals: 18)
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT")

  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    guard let result = formatter.date(from: string) else {
      fatalError("Could not parse ISO8601 full-date string: \(string)")
    }
    return result
  }

  /// Records every id passed to the metadata lookup so the suite can assert
  /// "exactly one point lookup per distinct token, then cached".
  private actor RecordingLookup {
    private(set) var ids: [String] = []

    let table: [String: CryptoRegistration]

    init(_ table: [String: CryptoRegistration]) { self.table = table }

    func lookup(_ id: String) async throws -> CryptoRegistration? {
      ids.append(id)
      return table[id]
    }

    var count: Int { ids.count }
  }

  private func makeService(
    prices: [String: [String: Decimal]] = [:],
    lookup: RecordingLookup
  ) throws -> CryptoPriceService {
    CryptoPriceService(
      clients: [FixedCryptoPriceClient(prices: prices)],
      database: try ProfileIndexDatabase.openInMemory(),
      metadataLookup: { try await lookup.lookup($0) })
  }

  @Test
  func hydratesOnMissThenCachesPerToken() async throws {
    let lookup = RecordingLookup([
      "1:native": CryptoRegistration(instrument: eth, mapping: ethMapping)
    ])
    let service = try makeService(
      prices: ["1:native": ["2026-04-10": dec("1623.45")]], lookup: lookup)
    let first = try await service.price(for: eth, on: date("2026-04-10"))
    let second = try await service.price(for: eth, on: date("2026-04-10"))
    #expect(first == dec("1623.45"))
    #expect(second == dec("1623.45"))
    #expect(await lookup.count == 1)  // one point lookup, then cached
  }

  @Test
  func wrappedNativePricesViaNativeRegistration() async throws {
    let lookup = RecordingLookup([
      "1:native": CryptoRegistration(instrument: eth, mapping: ethMapping)
    ])
    let service = try makeService(
      prices: ["1:native": ["2026-04-10": dec("1623.45")]], lookup: lookup)
    let price = try await service.price(for: weth, on: date("2026-04-10"))
    #expect(price == dec("1623.45"))
    #expect(await lookup.ids == ["1:native"])  // resolved by native id, never the WETH contract
  }

  @Test
  func unknownIdThrowsNoProviderMapping() async throws {
    let lookup = RecordingLookup([:])
    let service = try makeService(lookup: lookup)
    await #expect(throws: ConversionError.noProviderMapping(instrumentId: eth.id)) {
      _ = try await service.price(for: eth, on: date("2026-04-10"))
    }
  }

  @Test
  func purgeEvictsMetadataCache() async throws {
    let lookup = RecordingLookup([
      "1:native": CryptoRegistration(instrument: eth, mapping: ethMapping)
    ])
    let service = try makeService(
      prices: ["1:native": ["2026-04-10": dec("1623.45")]], lookup: lookup)
    _ = try await service.price(for: eth, on: date("2026-04-10"))
    await service.purgeCache(instrumentId: eth.id)
    _ = try await service.price(for: eth, on: date("2026-04-10"))
    #expect(await lookup.count == 2)  // re-resolved after eviction
  }

  @Test
  func purgeNativeEvictsWrappedNativeCache() async throws {
    let lookup = RecordingLookup([
      "1:native": CryptoRegistration(instrument: eth, mapping: ethMapping)
    ])
    let service = try makeService(
      prices: ["1:native": ["2026-04-10": dec("1623.45")]], lookup: lookup)
    // Prime WETH's metadata cache — resolves via the native id once.
    _ = try await service.price(for: weth, on: date("2026-04-10"))
    #expect(await lookup.count == 1)
    // Purge the *native* id; the wrapper's cached entry must cascade-evict.
    await service.purgeCache(instrumentId: eth.id)
    _ = try await service.price(for: weth, on: date("2026-04-10"))
    #expect(await lookup.count == 2)  // wrapper re-resolved after native purge
  }

  @Test
  func purgeWrappedNativeEvictsNativeCache() async throws {
    let lookup = RecordingLookup([
      "1:native": CryptoRegistration(instrument: eth, mapping: ethMapping)
    ])
    let service = try makeService(
      prices: ["1:native": ["2026-04-10": dec("1623.45")]], lookup: lookup)
    // Prime WETH — `registration(for:)` co-stores the entry under BOTH the
    // WETH id and the resolved native id (`1:native`).
    _ = try await service.price(for: weth, on: date("2026-04-10"))
    #expect(await lookup.count == 1)
    // Purge the *wrapper* id; the co-stored native entry must cascade-evict so
    // no stale `1:native` hit survives.
    await service.purgeCache(instrumentId: weth.id)
    _ = try await service.price(for: eth, on: date("2026-04-10"))
    #expect(await lookup.count == 2)  // native re-resolved after wrapper purge
  }
}

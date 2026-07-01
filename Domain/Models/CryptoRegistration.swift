// Domain/Models/CryptoRegistration.swift
// swiftlint:disable multiline_arguments

import Foundation

/// Pairs a crypto instrument with its price provider mapping for persistence.
struct CryptoRegistration {
  let instrument: Instrument
  let mapping: CryptoProviderMapping
  /// How aggregation should treat this token's fiat value. Distinct from
  /// "rate unavailable" — `.unpriced` and `.spam` are intentionally zero,
  /// not errors. Defaults to `.priced` for rows decoded without the field
  /// and for built-in presets.
  var pricingStatus: TokenPricingStatus = .priced

  /// Builds an `[instrumentId: assetKey]` lookup from a set of crypto
  /// registrations. An instrument absent from the result is treated by callers
  /// as keyed by its own id — it matches no other instrument. On a duplicate
  /// instrument id, the last entry wins.
  static func assetKeys(from registrations: [CryptoRegistration]) -> [String: String] {
    registrations.reduce(into: [String: String]()) { map, reg in
      map[reg.instrument.id] = reg.mapping.assetKey
    }
  }

  /// Fetches all crypto registrations from `registry` and folds them into the
  /// `[instrumentId: assetKey]` rollup map. Returns an empty map when `registry`
  /// is nil. Throws `CancellationError` if the task is cancelled, and rethrows
  /// any backing-store error — callers decide how to log/degrade.
  static func assetKeys(
    from registry: (any InstrumentRegistryRepository)?
  ) async throws -> [String: String] {
    guard let registry else { return [:] }
    let registrations = try await registry.allCryptoRegistrations()
    try Task.checkCancellation()
    return assetKeys(from: registrations)
  }

  /// Hand-curated registrations seeded into every profile at session
  /// startup so common chain native gas tokens (ETH on Ethereum mainnet;
  /// MATIC on Polygon) and well-known ERC-20s (OP, UNI, ENS, plus the
  /// canonical BTC entry) carry a real provider mapping before any
  /// transaction references them. Without this seed, wallet sync's
  /// `ensureInstrumentReadable` would land a placeholder
  /// `InstrumentRow` with `pricingStatus=.priced` and no mapping —
  /// which `allCryptoRegistrations()` projects to nil and which
  /// `cryptoUsdPrice` then can't resolve, throwing
  /// `ConversionError.noProviderMapping`. See issue #791.
  ///
  /// L2 ETH variants (Optimism `10:native`, Base `8453:native`) are
  /// omitted: `ChainConfig` aliases them to the canonical `1:native` so
  /// they never need their own preset entry.
  /// `registerBuiltInPresetsIfMissing` skips any preset whose `assetKey`
  /// already matches an existing canonical registration, which prevents a
  /// stale preset from re-minting a retired id.
  static let builtInPresets: [CryptoRegistration] = [
    CryptoRegistration(
      instrument: .crypto(
        chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8),
      mapping: CryptoProviderMapping(
        instrumentId: "0:native", coingeckoId: "bitcoin",
        cryptocompareSymbol: "BTC", binanceSymbol: "BTCUSDT"
      )
    ),
    CryptoRegistration(
      instrument: .crypto(
        chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "1:native", coingeckoId: "ethereum",
        cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
      )
    ),
    CryptoRegistration(
      instrument: .crypto(
        chainId: 137, contractAddress: nil, symbol: "MATIC", name: "Polygon", decimals: 18),
      mapping: CryptoProviderMapping(
        instrumentId: "137:native", coingeckoId: "polygon-ecosystem-token",
        cryptocompareSymbol: "MATIC", binanceSymbol: "POLUSDT"
      )
    ),
    CryptoRegistration(
      instrument: .crypto(
        chainId: 10,
        contractAddress: "0x4200000000000000000000000000000000000042",
        symbol: "OP", name: "Optimism", decimals: 18
      ),
      mapping: CryptoProviderMapping(
        instrumentId: "10:0x4200000000000000000000000000000000000042",
        coingeckoId: "optimism", cryptocompareSymbol: "OP", binanceSymbol: "OPUSDT"
      )
    ),
    CryptoRegistration(
      instrument: .crypto(
        chainId: 1,
        contractAddress: "0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984",
        symbol: "UNI", name: "Uniswap", decimals: 18
      ),
      mapping: CryptoProviderMapping(
        instrumentId: "1:0x1f9840a85d5af5bf1d1762f925bdaddc4201f984",
        coingeckoId: "uniswap", cryptocompareSymbol: "UNI", binanceSymbol: "UNIUSDT"
      )
    ),
    CryptoRegistration(
      instrument: .crypto(
        chainId: 1,
        contractAddress: "0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72",
        symbol: "ENS", name: "Ethereum Name Service", decimals: 18
      ),
      mapping: CryptoProviderMapping(
        instrumentId: "1:0xc18360217d8f7ab5e7c516566761ea12ce7f9d72",
        coingeckoId: "ethereum-name-service", cryptocompareSymbol: "ENS", binanceSymbol: "ENSUSDT"
      )
    ),
    // Canonical mainnet stablecoin presets. Every L2 USDC/USDT is collapsed
    // onto these ids by `CanonicalInstrumentResolver.staticBaseMap`; these
    // rows must exist locally so leg resolution finds a real cryptoToken row
    // (6 decimals) rather than falling back to `Instrument.fiat(code:)`
    // (2 decimals). Stablecoin pricing is handled by `StablecoinPriceClient`
    // ($1 peg); the provider fields support deep-history fallback only.
    CryptoRegistration(
      instrument: .crypto(
        chainId: 1,
        contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        symbol: "USDC", name: "USD Coin", decimals: 6
      ),
      mapping: CryptoProviderMapping(
        instrumentId: "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
        coingeckoId: "usd-coin", cryptocompareSymbol: "USDC", binanceSymbol: "USDCUSDT"
      )
    ),
    CryptoRegistration(
      instrument: .crypto(
        chainId: 1,
        contractAddress: "0xdac17f958d2ee523a2206206994597c13d831ec7",
        symbol: "USDT", name: "Tether", decimals: 6
      ),
      mapping: CryptoProviderMapping(
        instrumentId: "1:0xdac17f958d2ee523a2206206994597c13d831ec7",
        coingeckoId: "tether", cryptocompareSymbol: "USDT", binanceSymbol: nil
      )
    ),
  ]
}

extension CryptoRegistration: Sendable {}

extension CryptoRegistration: Hashable {}

extension CryptoRegistration: Identifiable {
  var id: String { instrument.id }
}

extension CryptoRegistration: Codable {
  private enum CodingKeys: String, CodingKey {
    case instrument
    case mapping
    case pricingStatus
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.instrument = try container.decode(Instrument.self, forKey: .instrument)
    self.mapping = try container.decode(CryptoProviderMapping.self, forKey: .mapping)
    self.pricingStatus =
      try container.decodeIfPresent(TokenPricingStatus.self, forKey: .pricingStatus) ?? .priced
  }
}

import Testing

@testable import Moolah

/// `InstrumentRow.cryptoMapping()` fills in the CryptoCompare price symbol
/// for recognised tokens whose resolution never recorded one — giving
/// CoinGecko-only tokens (e.g. USDC, DAI) a date-anchored deep-history
/// provider. The symbol comes from the bundled `CanonicalTokenRegistry`.
@Suite("InstrumentRow.cryptoMapping")
struct InstrumentRowCryptoMappingTests {
  /// Builds a crypto `InstrumentRow` with the provider columns under test;
  /// everything else is incidental.
  private func row(
    id: String,
    chainId: Int?,
    contractAddress: String?,
    coingeckoId: String? = nil,
    cryptocompareSymbol: String? = nil,
    binanceSymbol: String? = nil,
    ticker: String = "TKN",
    pricingStatus: TokenPricingStatus = .priced
  ) -> InstrumentRow {
    InstrumentRow(
      id: id,
      recordName: id,
      kind: "cryptoToken",
      name: "Token",
      decimals: 18,
      ticker: ticker,
      exchange: nil,
      chainId: chainId,
      contractAddress: contractAddress,
      coingeckoId: coingeckoId,
      cryptocompareSymbol: cryptocompareSymbol,
      binanceSymbol: binanceSymbol,
      encodedSystemFields: nil,
      pricingStatus: pricingStatus.rawValue)
  }

  private static let usdcEthereum = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"

  @Test("A known token with no CryptoCompare symbol gets the bundled one")
  func knownTokenGainsBundledSymbol() throws {
    let mapping = try #require(
      row(
        id: "1:\(Self.usdcEthereum)",
        chainId: 1,
        contractAddress: Self.usdcEthereum,
        coingeckoId: "usd-coin"
      ).cryptoMapping())
    #expect(mapping.coingeckoId == "usd-coin")
    #expect(mapping.cryptocompareSymbol == "USDC")
  }

  @Test("An explicitly resolved CryptoCompare symbol is never overridden")
  func resolvedSymbolWins() throws {
    let mapping = try #require(
      row(
        id: "1:\(Self.usdcEthereum)",
        chainId: 1,
        contractAddress: Self.usdcEthereum,
        coingeckoId: "usd-coin",
        cryptocompareSymbol: "USDC-RESOLVED"
      ).cryptoMapping())
    #expect(mapping.cryptocompareSymbol == "USDC-RESOLVED")
  }

  @Test("An unrecognised token gains no CryptoCompare symbol")
  func unknownTokenStaysNil() throws {
    let mapping = try #require(
      row(
        id: "1:0x000000000000000000000000000000000000dead",
        chainId: 1,
        contractAddress: "0x000000000000000000000000000000000000dead",
        coingeckoId: "obscure-token"
      ).cryptoMapping())
    #expect(mapping.cryptocompareSymbol == nil)
  }

  @Test("A known token with only the bundled symbol still yields a mapping")
  func bundledSymbolAloneProducesMapping() throws {
    // No coingecko / binance / stored cryptocompare symbol — the row would
    // otherwise have no provider mapping, but its canonical address alone
    // makes it priceable via CryptoCompare.
    let mapping = try #require(
      row(
        id: "1:\(Self.usdcEthereum)",
        chainId: 1,
        contractAddress: Self.usdcEthereum
      ).cryptoMapping())
    #expect(mapping.cryptocompareSymbol == "USDC")
  }

  @Test("The bundled symbol is the canonical one, not the row's ticker")
  func bundledSymbolIgnoresMisleadingTicker() throws {
    let mapping = try #require(
      row(
        id: "1:\(Self.usdcEthereum)",
        chainId: 1,
        contractAddress: Self.usdcEthereum,
        coingeckoId: "usd-coin",
        ticker: "USDC-FAKE"
      ).cryptoMapping())
    #expect(mapping.cryptocompareSymbol == "USDC")
  }

  @Test("An unpriced known token gains no bundled symbol")
  func unpricedTokenGainsNoBundledSymbol() throws {
    // Coingecko mapping is still present, but the bundled fallback is gated
    // to `.priced`, so `.unpriced` rows project exactly as before.
    let mapping = try #require(
      row(
        id: "1:\(Self.usdcEthereum)",
        chainId: 1,
        contractAddress: Self.usdcEthereum,
        coingeckoId: "usd-coin",
        pricingStatus: .unpriced
      ).cryptoMapping())
    #expect(mapping.cryptocompareSymbol == nil)
  }

  @Test("A spam known token gains no bundled symbol")
  func spamTokenGainsNoBundledSymbol() throws {
    let mapping = try #require(
      row(
        id: "1:\(Self.usdcEthereum)",
        chainId: 1,
        contractAddress: Self.usdcEthereum,
        coingeckoId: "usd-coin",
        pricingStatus: .spam
      ).cryptoMapping())
    #expect(mapping.cryptocompareSymbol == nil)
  }
}

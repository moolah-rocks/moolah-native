import Foundation
import Testing

@testable import Moolah

@Suite("Instrument.chainDisplayName")
struct InstrumentChainDisplayNameTests {
  @Test("Native ETH on mainnet reads as Ethereum")
  func mainnetEth() {
    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    #expect(eth.chainDisplayName == "Ethereum")
  }

  @Test("Native ETH on Optimism reads as Optimism")
  func optimismEth() {
    let eth = Instrument.crypto(
      chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    #expect(eth.chainDisplayName == "Optimism")
  }

  @Test("Native ETH on Base reads as Base")
  func baseEth() {
    let eth = Instrument.crypto(
      chainId: 8453, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    #expect(eth.chainDisplayName == "Base")
  }

  @Test("Unknown chain id falls back to the numbered chain label")
  func unknownChain() {
    let token = Instrument.crypto(
      chainId: 9999, contractAddress: "0xabc", symbol: "FOO", name: "Foo", decimals: 18)
    #expect(token.chainDisplayName == "Chain 9999")
  }

  @Test("Crypto token with no chain id has no chain name (not Bitcoin)")
  func cryptoMissingChainId() {
    // A crypto instrument deserialized without a chain id must read as
    // absent, not silently fall back to chain 0 ("Bitcoin").
    let token = Instrument(
      id: "orphan", kind: .cryptoToken, name: "Orphan", decimals: 18,
      ticker: "ORP", exchange: nil, chainId: nil, contractAddress: nil)
    #expect(token.chainDisplayName == nil)
  }

  @Test("Fiat instruments have no chain name")
  func fiatHasNoChain() {
    #expect(Instrument.fiat(code: "USD").chainDisplayName == nil)
  }

  @Test("Stock instruments have no chain name")
  func stockHasNoChain() {
    let stock = Instrument.stock(ticker: "AAPL", exchange: "NASDAQ", name: "Apple")
    #expect(stock.chainDisplayName == nil)
  }
}

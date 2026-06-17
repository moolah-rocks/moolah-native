import Testing

@testable import Moolah

@Suite("DefiLlamaCoinID")
struct DefiLlamaCoinIDTests {
  @Test("ERC-20 on Ethereum derives chain:address")
  func erc20Ethereum() {
    #expect(
      DefiLlamaCoinID.make(instrumentId: "1:0xc02aaa39", coingeckoId: nil)
        == "ethereum:0xc02aaa39")
  }

  @Test("ERC-20 on Optimism derives chain:address")
  func erc20Optimism() {
    #expect(
      DefiLlamaCoinID.make(
        instrumentId: "10:0x4200000000000000000000000000000000000042", coingeckoId: nil)
        == "optimism:0x4200000000000000000000000000000000000042")
  }

  @Test("native coin uses coingecko id")
  func nativeUsesCoingecko() {
    #expect(
      DefiLlamaCoinID.make(instrumentId: "1:native", coingeckoId: "ethereum")
        == "coingecko:ethereum")
  }

  @Test("native BTC uses coingecko:bitcoin")
  func nativeBitcoin() {
    #expect(
      DefiLlamaCoinID.make(instrumentId: "0:native", coingeckoId: "bitcoin")
        == "coingecko:bitcoin")
  }

  @Test("unknown chain ERC-20 returns nil")
  func unknownChain() {
    #expect(DefiLlamaCoinID.make(instrumentId: "999999:0xabc", coingeckoId: nil) == nil)
  }

  @Test("native without coingecko id returns nil")
  func nativeWithoutCoingecko() {
    #expect(DefiLlamaCoinID.make(instrumentId: "1:native", coingeckoId: nil) == nil)
  }
}

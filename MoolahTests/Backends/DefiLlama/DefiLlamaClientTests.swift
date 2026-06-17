import Foundation
import Testing

@testable import Moolah

@Suite("DefiLlamaClient", .serialized)
final class DefiLlamaClientTests {
  deinit { StubURLProtocol.handlers = [:] }

  private func makeNetworking() -> NetworkingServices {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return NetworkingServices(session: URLSession(configuration: config))
  }

  private let wethMapping = CryptoProviderMapping(
    instrumentId: "1:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
    coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil)

  @Test("dailyPrices parses /chart, buckets by UTC day keeping the last point")
  func chartDayBucket() async throws {
    let body = """
      {"coins":{"ethereum:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2":{
        "symbol":"WETH","confidence":0.99,"prices":[
          {"timestamp":1704067200,"price":2275.21},
          {"timestamp":1704096000,"price":2300.00},
          {"timestamp":1704153600,"price":2339.59}]}}}
      """
    // StubURLProtocol dispatches by "<host>:<path>"
    let coinId = "ethereum:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"
    StubURLProtocol.handlers["coins.llama.fi:/chart/\(coinId)"] = { _ in
      (HTTPURLResponse.ok(etag: ""), Data(body.utf8))
    }
    let client = DefiLlamaClient(networking: makeNetworking())
    let from = Date(timeIntervalSince1970: 1_704_067_200)
    let to = Date(timeIntervalSince1970: 1_704_153_600)
    let prices = try await client.dailyPrices(for: wethMapping, in: from...to)
    #expect(prices["2024-01-01"] == Decimal(string: "2300.00"))  // last point of the day
    #expect(prices["2024-01-02"] == Decimal(string: "2339.59"))
  }

  @Test("confidence below the floor drops the coin (empty result)")
  func confidenceGate() async throws {
    let body = """
      {"coins":{"ethereum:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2":{
        "symbol":"WETH","confidence":0.1,"prices":[{"timestamp":1704067200,"price":2275.21}]}}}
      """
    let coinId = "ethereum:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"
    StubURLProtocol.handlers["coins.llama.fi:/chart/\(coinId)"] = { _ in
      (HTTPURLResponse.ok(etag: ""), Data(body.utf8))
    }
    let client = DefiLlamaClient(networking: makeNetworking())
    let day = Date(timeIntervalSince1970: 1_704_067_200)
    let prices = try await client.dailyPrices(for: wethMapping, in: day...day)
    #expect(prices.isEmpty)
  }

  @Test("currentPrices batches and remaps coin ids back to instrument ids")
  func currentBatch() async throws {
    let body = """
      {"coins":{
        "ethereum:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2":{"price":2300.0,"confidence":0.99},
        "coingecko:bitcoin":{"price":65000.0,"confidence":0.99}}}
      """
    // currentPrices sorts coin ids before joining, so the path is deterministic.
    // Sorted: "coingecko:bitcoin" < "ethereum:0x..."
    let coinPath =
      "coingecko:bitcoin,ethereum:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"
    StubURLProtocol.handlers["coins.llama.fi:/prices/current/\(coinPath)"] = { _ in
      (HTTPURLResponse.ok(etag: ""), Data(body.utf8))
    }
    let btc = CryptoProviderMapping(
      instrumentId: "0:native", coingeckoId: "bitcoin",
      cryptocompareSymbol: nil, binanceSymbol: nil)
    let client = DefiLlamaClient(networking: makeNetworking())
    let result = try await client.currentPrices(for: [wethMapping, btc])
    #expect(result["1:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"] == Decimal(string: "2300.0"))
    #expect(result["0:native"] == Decimal(string: "65000.0"))
  }

  @Test("undrivable coin id throws noProviderMapping")
  func undrivableThrows() async {
    let bad = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: nil,
      cryptocompareSymbol: nil, binanceSymbol: nil)
    let client = DefiLlamaClient(networking: makeNetworking())
    await #expect(throws: CryptoPriceError.self) {
      _ = try await client.dailyPrice(for: bad, on: Date(timeIntervalSince1970: 1_704_067_200))
    }
  }
}

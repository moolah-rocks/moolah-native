import Foundation

/// Keyless DefiLlama (`coins.llama.fi`) price client. First in the
/// `CryptoPriceService` chain. Derives its coin id from the contract address
/// already in `instrumentId` (native coins via `coingecko:{id}`), so it needs
/// no token-list catalog. USD-denominated. A coin whose confidence is below
/// `confidenceFloor` is treated as a miss so the chain falls through.
struct DefiLlamaClient: CryptoPriceClient, Sendable {
  var syncProvider: SyncProvider { .defiLlama }

  private let networking: NetworkingServices
  let supportCache: DefiLlamaSupportCache?
  private let confidenceFloor: Decimal

  init(
    networking: NetworkingServices,
    supportCache: DefiLlamaSupportCache? = nil,
    confidenceFloor: Decimal = 0.2
  ) {
    self.networking = networking
    self.supportCache = supportCache
    self.confidenceFloor = confidenceFloor
  }

  private var http: RateLimitedHTTPClient { networking.client(forHost: "coins.llama.fi") }

  func dailyPrice(for mapping: CryptoProviderMapping, on date: Date) async throws -> Decimal {
    let prices = try await dailyPrices(for: mapping, in: date...date)
    let day = DefiLlamaWireFormat.isoDay(from: date.timeIntervalSince1970)
    guard let price = prices[day] else {
      throw CryptoPriceError.noPriceAvailable(tokenId: mapping.instrumentId, date: day)
    }
    return price
  }

  func dailyPrices(
    for mapping: CryptoProviderMapping, in range: ClosedRange<Date>
  ) async throws -> [String: Decimal] {
    guard
      let coinId = DefiLlamaCoinID.make(
        instrumentId: mapping.instrumentId, coingeckoId: mapping.coingeckoId)
    else {
      throw CryptoPriceError.noProviderMapping(
        tokenId: mapping.instrumentId, provider: "DefiLlama")
    }
    let url = DefiLlamaWireFormat.chartURL(
      coinId: coinId, from: range.lowerBound, to: range.upperBound)
    let (data, _) = try await http.data(for: URLRequest(url: url))
    return try DefiLlamaWireFormat.parseChart(data, confidenceFloor: confidenceFloor)
  }

  func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal] {
    var coinToInstrument: [String: String] = [:]
    for mapping in mappings {
      if let coinId = DefiLlamaCoinID.make(
        instrumentId: mapping.instrumentId, coingeckoId: mapping.coingeckoId)
      {
        coinToInstrument[coinId] = mapping.instrumentId
      }
    }
    guard !coinToInstrument.isEmpty else { return [:] }
    let url = DefiLlamaWireFormat.currentURL(coinIds: coinToInstrument.keys.sorted())
    let (data, _) = try await http.data(for: URLRequest(url: url))
    let byCoin = try DefiLlamaWireFormat.parseCurrent(data, confidenceFloor: confidenceFloor)
    var result: [String: Decimal] = [:]
    for (coinId, price) in byCoin {
      if let instrumentId = coinToInstrument[coinId] { result[instrumentId] = price }
    }
    return result
  }
}

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

  /// 24h staleness window — matches `CatalogRefresh.defaultMaxAge`.
  private static let supportMaxAge: TimeInterval = 24 * 3_600

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

    // Short-circuit a fresh "unsupported" verdict so we don't pay a round-trip
    // for a token DefiLlama is known not to price.
    if let cached = await supportCache?.support(for: mapping.instrumentId),
      !cached.supported,
      Date().timeIntervalSince(cached.lastChecked) < Self.supportMaxAge
    {
      throw CryptoPriceError.noProviderMapping(
        tokenId: mapping.instrumentId, provider: "DefiLlama")
    }

    let url = DefiLlamaWireFormat.chartURL(
      coinId: coinId, from: range.lowerBound, to: range.upperBound)
    let (data, _) = try await http.data(for: URLRequest(url: url))
    let prices = try DefiLlamaWireFormat.parseChart(data, confidenceFloor: confidenceFloor)

    // Opportunistically promote support when the fetch returned prices.
    // Only update the cache on a non-empty result so a legitimately empty
    // window (e.g. deep-history before a token's first DEX liquidity, or a
    // low-confidence read gated by the floor) does not demote a token that
    // is genuinely supported. The `/prices/first` startup probe
    // (`refreshSupport`) is the sole writer of `supported: false`.
    // ISO `YYYY-MM-DD` strings compare chronologically, so taking the min
    // keeps the recorded earliest date monotonically non-increasing.
    if !prices.isEmpty {
      let windowFloor = prices.keys.min()
      let existingFloor = await supportCache?.support(for: mapping.instrumentId)?.earliestDate
      let floor = [existingFloor, windowFloor].compactMap { $0 }.min()
      await supportCache?.upsert(
        instrumentId: mapping.instrumentId,
        supported: true,
        earliestDate: floor,
        lastChecked: Date())
    }

    return prices
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

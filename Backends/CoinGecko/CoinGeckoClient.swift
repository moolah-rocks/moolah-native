import Foundation

struct CoinGeckoClient: CryptoPriceClient, Sendable {
  var syncProvider: SyncProvider { .coinGecko }

  /// Pro-tier base URL. Used whenever the user has supplied a CoinGecko
  /// Pro API key. Authenticated via the `x_cg_pro_api_key` query item.
  private static let proBaseURL =
    URL(string: "https://pro-api.coingecko.com/api/v3") ?? URL(fileURLWithPath: "/")
  /// Public free-tier base URL. Used when no API key is configured; no
  /// auth query item is sent. Subject to CoinGecko's anonymous rate
  /// limits (~30 req/min) — the price-service falls back to
  /// Binance if a request 429s.
  private static let publicBaseURL =
    URL(string: "https://api.coingecko.com/api/v3") ?? URL(fileURLWithPath: "/")
  /// Resolves the key per request (not once at construction) so a Pro key
  /// entered in Settings flips both the request URL's host *and* the
  /// rate-limit gate — looked up from `networking` for the same host — on
  /// the next fetch. Reading the key once and binding `http` to one host at
  /// init let the two diverge when the key changed mid-session.
  private let apiKeyProvider: @Sendable () -> String?
  private let networking: NetworkingServices

  init(apiKeyProvider: @Sendable @escaping () -> String?, networking: NetworkingServices) {
    self.apiKeyProvider = apiKeyProvider
    self.networking = networking
  }

  /// The free public CoinGecko host. Used when no key is configured.
  private static let publicHost = "api.coingecko.com"
  /// The authenticated Pro host. Used whenever a key is configured.
  private static let proHost = "pro-api.coingecko.com"

  /// Picks the host that matches the key the URL builders target so the
  /// rate-limit gate and the request URL never diverge. Internal (not
  /// `private`) so the catalog refresh path can resolve the same host from
  /// the one place these literals live (see `SQLiteCoinGeckoCatalog+Refresh`).
  static func host(apiKey: String) -> String {
    apiKey.isEmpty ? publicHost : proHost
  }

  /// Resolves the base URL by key presence: non-empty → Pro host,
  /// empty → public host. Static so the URL builders can call it
  /// without an instance.
  private static func baseURL(apiKey: String) -> URL {
    apiKey.isEmpty ? publicBaseURL : proBaseURL
  }

  /// `x_cg_pro_api_key` query item, or `nil` when no key is supplied
  /// (free public endpoint accepts the request without auth).
  private static func authQueryItem(apiKey: String) -> URLQueryItem? {
    apiKey.isEmpty ? nil : URLQueryItem(name: "x_cg_pro_api_key", value: apiKey)
  }

  func dailyPrice(for mapping: CryptoProviderMapping, on date: Date) async throws -> Decimal {
    let prices = try await dailyPrices(for: mapping, in: date...date)
    let dateString = date.iso8601DateOnlyString
    guard let price = prices[dateString] else {
      throw CryptoPriceError.noPriceAvailable(tokenId: mapping.instrumentId, date: dateString)
    }
    return price
  }

  func dailyPrices(
    for mapping: CryptoProviderMapping, in range: ClosedRange<Date>
  ) async throws -> [String: Decimal] {
    guard let coinId = mapping.coingeckoId else {
      throw CryptoPriceError.noProviderMapping(tokenId: mapping.instrumentId, provider: "CoinGecko")
    }
    let apiKey = apiKeyProvider() ?? ""
    let url = Self.marketChartRangeURL(
      coinId: coinId, from: range.lowerBound, to: range.upperBound, apiKey: apiKey)
    let http = networking.client(forHost: Self.host(apiKey: apiKey))
    let (data, _) = try await http.data(for: URLRequest(url: url))
    return try Self.parseMarketChartResponse(data)
  }

  func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal] {
    let idToMapping = Dictionary(
      mappings.compactMap { mapping -> (String, CryptoProviderMapping)? in
        guard let id = mapping.coingeckoId else { return nil }
        return (id, mapping)
      },
      uniquingKeysWith: { first, _ in first }
    )
    guard !idToMapping.isEmpty else { return [:] }

    let apiKey = apiKeyProvider() ?? ""
    let url = Self.simplePriceURL(coinIds: Array(idToMapping.keys), apiKey: apiKey)
    let http = networking.client(forHost: Self.host(apiKey: apiKey))
    let (data, _) = try await http.data(for: URLRequest(url: url))
    let coinPrices = try Self.parseSimplePriceResponse(data)

    var result: [String: Decimal] = [:]
    for (coinId, price) in coinPrices {
      if let mapping = idToMapping[coinId] {
        result[mapping.instrumentId] = price
      }
    }
    return result
  }

  // MARK: - URL builders (internal for testing)

  /// Builds the **date-anchored** `market_chart/range` URL for the
  /// requested `[from, to]` window, using UNIX-second timestamps.
  ///
  /// The `market_chart?days=N` endpoint returns the last N days from
  /// *now*, so it cannot fetch an arbitrary historical window;
  /// `market_chart/range` fetches exactly the dates asked for, which is
  /// what backfilling a gap in the price cache requires.
  ///
  /// `to` is extended by one day so the upper-bound day's prices are
  /// included: the range endpoint is timestamp-inclusive, so a midnight
  /// `to` returns no intraday points for that final day, and a single-day
  /// `from == to` request would otherwise be an empty window.
  ///
  /// For windows of 90 days or less the endpoint returns hourly
  /// granularity; `parseMarketChartResponse` keys by calendar day and
  /// keeps the last point per day, so each day resolves to its latest
  /// intraday price. Windows over 90 days return daily points directly.
  ///
  /// On the public/free tier CoinGecko serves only the last 365 days of
  /// history and 401s for older `from` values; the price service then
  /// falls through to the next provider in its chain.
  static func marketChartRangeURL(coinId: String, from: Date, to: Date, apiKey: String) -> URL {
    let pathURL = baseURL(apiKey: apiKey).appendingPathComponent(
      "coins/\(coinId)/market_chart/range")
    var components =
      URLComponents(url: pathURL, resolvingAgainstBaseURL: false) ?? URLComponents()
    let fromTimestamp = Int(from.timeIntervalSince1970)
    let toTimestamp = Int(to.timeIntervalSince1970) + 86_400
    var items: [URLQueryItem] = [
      URLQueryItem(name: "vs_currency", value: "usd"),
      URLQueryItem(name: "from", value: String(fromTimestamp)),
      URLQueryItem(name: "to", value: String(toTimestamp)),
    ]
    if let auth = authQueryItem(apiKey: apiKey) { items.append(auth) }
    components.queryItems = items
    return components.url ?? pathURL
  }

  // MARK: - Token resolution

  static func assetPlatformsURL(apiKey: String) -> URL {
    let pathURL = baseURL(apiKey: apiKey).appendingPathComponent("asset_platforms")
    var components =
      URLComponents(url: pathURL, resolvingAgainstBaseURL: false) ?? URLComponents()
    components.queryItems = authQueryItem(apiKey: apiKey).map { [$0] }
    return components.url ?? pathURL
  }

  /// `/coins/list?include_platform=true` — the full coin catalog the
  /// `SQLiteCoinGeckoCatalog` refresh downloads. Built here (rather than as
  /// a hardcoded literal in the catalog) so host selection and the auth
  /// query item stay in one tested place alongside the other endpoints.
  static func coinsListURL(apiKey: String) -> URL {
    let pathURL = baseURL(apiKey: apiKey).appendingPathComponent("coins/list")
    var components =
      URLComponents(url: pathURL, resolvingAgainstBaseURL: false) ?? URLComponents()
    var items: [URLQueryItem] = [
      URLQueryItem(name: "include_platform", value: "true")
    ]
    if let auth = authQueryItem(apiKey: apiKey) { items.append(auth) }
    components.queryItems = items
    return components.url ?? pathURL
  }

  static func contractLookupURL(platformId: String, contractAddress: String, apiKey: String) -> URL
  {
    let pathURL = baseURL(apiKey: apiKey).appendingPathComponent(
      "coins/\(platformId)/contract/\(contractAddress.lowercased())")
    var components =
      URLComponents(url: pathURL, resolvingAgainstBaseURL: false) ?? URLComponents()
    components.queryItems = authQueryItem(apiKey: apiKey).map { [$0] }
    return components.url ?? pathURL
  }

  static func simplePriceURL(coinIds: [String], apiKey: String) -> URL {
    let pathURL = baseURL(apiKey: apiKey).appendingPathComponent("simple/price")
    var components =
      URLComponents(url: pathURL, resolvingAgainstBaseURL: false) ?? URLComponents()
    var items: [URLQueryItem] = [
      URLQueryItem(name: "ids", value: coinIds.joined(separator: ",")),
      URLQueryItem(name: "vs_currencies", value: "usd"),
    ]
    if let auth = authQueryItem(apiKey: apiKey) { items.append(auth) }
    components.queryItems = items
    return components.url ?? pathURL
  }

  // MARK: - Response parsers (internal for testing)

  static func parseMarketChartResponse(_ data: Data) throws -> [String: Decimal] {
    let container = try JSONDecoder().decode(MarketChartResponse.self, from: data)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    var result: [String: Decimal] = [:]
    for pair in container.prices {
      guard pair.count == 2 else { continue }
      let date = Date(timeIntervalSince1970: (pair[0] as NSDecimalNumber).doubleValue / 1000)
      let key = formatter.string(from: date)
      result[key] = pair[1]
    }
    return result
  }

  static func parseSimplePriceResponse(_ data: Data) throws -> [String: Decimal] {
    let raw = try JSONDecoder().decode([String: [String: Decimal]].self, from: data)
    var result: [String: Decimal] = [:]
    for (coinId, currencies) in raw {
      if let usd = currencies["usd"] {
        result[coinId] = usd
      }
    }
    return result
  }

  /// Parses the asset platforms response into a chain ID → platform slug mapping.
  static func parseAssetPlatformsResponse(_ data: Data) throws -> [Int: String] {
    let platforms = try JSONDecoder().decode([AssetPlatform].self, from: data)
    var mapping: [Int: String] = [:]
    for platform in platforms {
      if let chainId = platform.chainIdentifier {
        mapping[chainId] = platform.id
      }
    }
    return mapping
  }

  struct ContractLookupResult: Sendable {
    let id: String
    let symbol: String
    let name: String
    let decimals: Int?
  }

  /// Parses the contract lookup response to extract token details.
  static func parseContractLookupResponse(_ data: Data) throws -> ContractLookupResult {
    let raw = try JSONDecoder().decode(ContractLookupRaw.self, from: data)
    let decimals = raw.detailPlatforms.values.first?.decimalPlace
    return ContractLookupResult(
      id: raw.id, symbol: raw.symbol, name: raw.name, decimals: decimals
    )
  }
}

private struct MarketChartResponse: Decodable {
  let prices: [[Decimal]]
}

private struct AssetPlatform: Decodable {
  let id: String
  let chainIdentifier: Int?
  let name: String

  enum CodingKeys: String, CodingKey {
    case id
    case chainIdentifier = "chain_identifier"
    case name
  }
}

private struct ContractLookupRaw: Decodable {
  let id: String
  let symbol: String
  let name: String
  /// Empty when the CoinGecko response omits `detail_platforms` entirely
  /// (e.g. newer endpoints or minimal test fixtures). A missing key and
  /// an explicit empty object are treated the same.
  let detailPlatforms: [String: DetailPlatform]

  enum CodingKeys: String, CodingKey {
    case id
    case symbol
    case name
    case detailPlatforms = "detail_platforms"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decode(String.self, forKey: .id)
    self.symbol = try container.decode(String.self, forKey: .symbol)
    self.name = try container.decode(String.self, forKey: .name)
    self.detailPlatforms =
      try container.decodeIfPresent([String: DetailPlatform].self, forKey: .detailPlatforms) ?? [:]
  }
}

private struct DetailPlatform: Decodable {
  let decimalPlace: Int?
  let contractAddress: String?

  enum CodingKeys: String, CodingKey {
    case decimalPlace = "decimal_place"
    case contractAddress = "contract_address"
  }
}

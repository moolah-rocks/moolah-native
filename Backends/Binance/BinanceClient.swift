import Foundation

struct BinanceClient: CryptoPriceClient, Sendable {
  var syncProvider: SyncProvider { .binance }

  private static let baseURLString = "https://api.binance.com"
  private static let baseURL =
    URL(string: baseURLString) ?? URL(fileURLWithPath: "/")
  private let http: RateLimitedHTTPClient
  private let usdtRateLookup: @Sendable (Date) async -> Decimal

  init(
    http: RateLimitedHTTPClient,
    usdtRateLookup: @escaping @Sendable (Date) async -> Decimal = { _ in Decimal(1) }
  ) {
    self.http = http
    self.usdtRateLookup = usdtRateLookup
  }

  func dailyPrice(for mapping: CryptoProviderMapping, on date: Date) async throws -> Decimal {
    let prices = try await dailyPrices(for: mapping, in: date...date)
    let dateString = Self.dateString(from: date)
    guard let price = prices[dateString] else {
      throw CryptoPriceError.noPriceAvailable(tokenId: mapping.instrumentId, date: dateString)
    }
    return price
  }

  func dailyPrices(
    for mapping: CryptoProviderMapping, in range: ClosedRange<Date>
  ) async throws -> [String: Decimal] {
    guard let symbol = mapping.binanceSymbol else {
      throw CryptoPriceError.noProviderMapping(tokenId: mapping.instrumentId, provider: "Binance")
    }

    var allPrices: [String: Decimal] = [:]
    let calendar = Calendar(identifier: .gregorian)
    var chunkStart = range.lowerBound

    // Binance max 1000 candles per request — paginate if needed
    while chunkStart <= range.upperBound {
      let candleWindowEnd =
        calendar.date(byAdding: .day, value: 999, to: chunkStart) ?? range.upperBound
      let chunkEnd = min(candleWindowEnd, range.upperBound)
      let url = Self.klinesURL(symbol: symbol, from: chunkStart, to: chunkEnd)
      let (data, _) = try await http.data(for: URLRequest(url: url))
      let chunk = try Self.parseKlinesResponse(data)
      for (key, value) in chunk { allPrices[key] = value }
      guard let next = calendar.date(byAdding: .day, value: 1, to: chunkEnd) else { break }
      chunkStart = next
    }

    let midDate = Date(
      timeIntervalSince1970: (range.lowerBound.timeIntervalSince1970
        + range.upperBound.timeIntervalSince1970) / 2
    )
    let rate = await usdtRateLookup(midDate)
    return Self.applyUsdtRate(allPrices, rate: rate)
  }

  func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal] {
    // Binance has no batch endpoint — fetch one at a time
    var result: [String: Decimal] = [:]
    for mapping in mappings {
      guard mapping.binanceSymbol != nil else { continue }
      do {
        let price = try await dailyPrice(for: mapping, on: Date())
        result[mapping.instrumentId] = price
      } catch {
        continue
      }
    }
    return result
  }

  // MARK: - URL builders (internal for testing)

  static func exchangeInfoURL() -> URL {
    baseURL.appendingPathComponent("/api/v3/exchangeInfo")
  }

  static func klinesURL(symbol: String, from: Date, to: Date) -> URL {
    let startMs = Int(from.timeIntervalSince1970 * 1000)
    let endMs = Int(to.timeIntervalSince1970 * 1000)
    let pathURL = baseURL.appendingPathComponent("/api/v3/klines")
    var components =
      URLComponents(url: pathURL, resolvingAgainstBaseURL: false) ?? URLComponents()
    components.queryItems = [
      URLQueryItem(name: "symbol", value: symbol),
      URLQueryItem(name: "interval", value: "1d"),
      URLQueryItem(name: "startTime", value: String(startMs)),
      URLQueryItem(name: "endTime", value: String(endMs)),
      URLQueryItem(name: "limit", value: "1000"),
    ]
    return components.url ?? pathURL
  }

  // MARK: - Response parsers (internal for testing)

  static func parseKlinesResponse(_ data: Data) throws -> [String: Decimal] {
    let klines = try JSONDecoder().decode([[KlineValue]].self, from: data)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    var result: [String: Decimal] = [:]
    for kline in klines {
      guard kline.count >= 5 else { continue }
      guard case .int(let openTimeMs) = kline[0],
        case .string(let closeStr) = kline[4],
        let close = Decimal(string: closeStr)
      else { continue }
      let date = Date(timeIntervalSince1970: TimeInterval(openTimeMs) / 1000)
      let key = formatter.string(from: date)
      result[key] = close
    }
    return result
  }

  /// Parses the exchange info response and returns the set of active USDT trading pair symbols.
  static func parseExchangeInfoResponse(_ data: Data) throws -> Set<String> {
    let container = try JSONDecoder().decode(ExchangeInfoContainer.self, from: data)
    var pairs: Set<String> = []
    for symbol in container.symbols {
      if symbol.quoteAsset == "USDT", symbol.status == "TRADING" {
        pairs.insert(symbol.symbol)
      }
    }
    return pairs
  }

  static func applyUsdtRate(_ prices: [String: Decimal], rate: Decimal) -> [String: Decimal] {
    prices.mapValues { $0 * rate }
  }

  private static func dateString(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter.string(from: date)
  }
}

// MARK: - Exchange info response types

private struct ExchangeInfoContainer: Decodable {
  let symbols: [ExchangeInfoSymbol]
}

private struct ExchangeInfoSymbol: Decodable {
  let symbol: String
  let baseAsset: String
  let quoteAsset: String
  let status: String
}

// MARK: - Binance kline array values are mixed types (int, string)

private enum KlineValue: Decodable {
  case int(Int)
  case string(String)
  case double(Double)

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let intValue = try? container.decode(Int.self) {
      self = .int(intValue)
      return
    }
    if let stringValue = try? container.decode(String.self) {
      self = .string(stringValue)
      return
    }
    if let doubleValue = try? container.decode(Double.self) {
      self = .double(doubleValue)
      return
    }
    throw DecodingError.typeMismatch(
      KlineValue.self,
      DecodingError.Context(
        codingPath: decoder.codingPath,
        debugDescription: "Unexpected kline value type"
      )
    )
  }
}

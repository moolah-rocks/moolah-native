import Foundation

enum YahooFinanceError: Error {
  case invalidResponse
  case apiError(code: String, description: String)
  case noData
}

struct YahooFinanceClient: StockPriceClient, Sendable {
  private static let baseURL =
    URL(string: "https://query2.finance.yahoo.com/v8/finance/chart/")
    ?? URL(fileURLWithPath: "/")
  private let http: RateLimitedHTTPClient

  init(http: RateLimitedHTTPClient) {
    self.http = http
  }

  func fetchDailyPrices(ticker: String, from: Date, to: Date) async throws -> StockPriceResponse {
    let url = Self.baseURL.appendingPathComponent(ticker)
    var components =
      URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
    components.queryItems = [
      URLQueryItem(name: "period1", value: String(Int(from.timeIntervalSince1970))),
      URLQueryItem(name: "period2", value: String(Int(to.timeIntervalSince1970))),
      URLQueryItem(name: "interval", value: "1d"),
    ]

    var request = URLRequest(url: components.url ?? url)
    request.setValue(
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)",
      forHTTPHeaderField: "User-Agent"
    )

    let (data, _) = try await http.data(for: request)
    return try Self.parseResponse(data)
  }

  static func parseResponse(_ data: Data) throws -> StockPriceResponse {
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    guard let chart = json?["chart"] as? [String: Any] else {
      throw YahooFinanceError.invalidResponse
    }

    // Check for error response
    if let error = chart["error"] as? [String: Any],
      let code = error["code"] as? String
    {
      let description = error["description"] as? String ?? "Unknown error"
      throw YahooFinanceError.apiError(code: code, description: description)
    }

    guard let results = chart["result"] as? [[String: Any]],
      let result = results.first
    else {
      throw YahooFinanceError.noData
    }

    // Extract currency from meta
    guard let meta = result["meta"] as? [String: Any],
      let currencyCode = meta["currency"] as? String
    else {
      throw YahooFinanceError.invalidResponse
    }
    let instrument = Instrument.fiat(code: currencyCode)

    // Extract timestamps
    guard let timestamps = result["timestamp"] as? [Int] else {
      throw YahooFinanceError.noData
    }

    // Extract adjusted close prices
    guard let indicators = result["indicators"] as? [String: Any],
      let adjcloseArray = indicators["adjclose"] as? [[String: Any]],
      let adjcloseData = adjcloseArray.first,
      let adjcloseValues = adjcloseData["adjclose"] as? [Any]
    else {
      throw YahooFinanceError.invalidResponse
    }

    // Zip timestamps with adjusted close, skipping nulls
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = TimeZone(identifier: "UTC")

    var prices: [String: Decimal] = [:]
    for (index, timestamp) in timestamps.enumerated() {
      guard index < adjcloseValues.count else { continue }
      // Skip null values (NSNull from JSON)
      guard let number = adjcloseValues[index] as? NSNumber else { continue }
      let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
      let dateString = formatter.string(from: date)
      // Use string conversion to avoid Double -> Decimal floating point issues
      prices[dateString] = Decimal(string: number.stringValue)
    }

    return StockPriceResponse(instrument: instrument, prices: prices)
  }
}

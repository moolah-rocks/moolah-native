import Foundation

/// URL builders + `Decodable` response parsers for the keyless DefiLlama
/// coins API (`coins.llama.fi`). All prices are USD. Coin ids are
/// comma-separated `{chain}:{address}` / `coingecko:{id}` tokens.
enum DefiLlamaWireFormat {
  private static let base = URL(string: "https://coins.llama.fi") ?? URL(fileURLWithPath: "/")

  /// Points per UTC day requested from `/chart` (`period=12h`).
  ///
  /// We oversample at 12h rather than `period=1d` because DefiLlama snaps each
  /// requested point to the nearest real observation (~00:00 / ~23:59). At `1d`
  /// those near-midnight timestamps alias against UTC-day buckets — consecutive
  /// points collide on one day and skip the next — silently dropping ~1 day in
  /// 5, even for max-confidence liquid tokens. Two points per day guarantees at
  /// least one lands in every UTC day, so `parseChart`'s last-per-day bucketing
  /// is dense. Finer than 12h does not recover more (genuinely sparse history
  /// stays sparse); 12h is the smallest period that closes the aliasing.
  private static let chartPointsPerDay = 2

  /// `/chart/{coin}?start=&span=&period=12h` — a 12-hourly series covering
  /// `[from, to]`, bucketed back to one price per UTC day by `parseChart`.
  /// `span` is the inclusive day count plus a 2-day buffer (so the final day is
  /// always included), times `chartPointsPerDay`.
  static func chartURL(coinId: String, from: Date, to: Date) -> URL {
    let pathURL = base.appendingPathComponent("chart").appendingPathComponent(coinId)
    var components = URLComponents(url: pathURL, resolvingAgainstBaseURL: false) ?? URLComponents()
    let days = max(0, Int(to.timeIntervalSince(from) / 86_400)) + 1 + 2
    components.queryItems = [
      URLQueryItem(name: "start", value: String(Int(from.timeIntervalSince1970))),
      URLQueryItem(name: "span", value: String(days * chartPointsPerDay)),
      URLQueryItem(name: "period", value: "12h"),
    ]
    return components.url ?? pathURL
  }

  /// `/prices/current/{coins}` — current USD price for many coins in one call.
  static func currentURL(coinIds: [String]) -> URL {
    base.appendingPathComponent("prices/current")
      .appendingPathComponent(coinIds.joined(separator: ","))
  }

  /// `/prices/first/{coins}` — earliest data point per coin (used by the probe).
  static func firstURL(coinIds: [String]) -> URL {
    base.appendingPathComponent("prices/first")
      .appendingPathComponent(coinIds.joined(separator: ","))
  }

  // MARK: - Response shapes

  private struct ChartPoint: Decodable {
    let timestamp: Double
    let price: Decimal
  }

  private struct ChartCoin: Decodable {
    let confidence: Decimal?
    let prices: [ChartPoint]
  }

  private struct ChartResponse: Decodable {
    let coins: [String: ChartCoin]
  }

  private struct CurrentCoin: Decodable {
    let price: Decimal
    let confidence: Decimal?
  }

  private struct CurrentResponse: Decodable {
    let coins: [String: CurrentCoin]
  }

  struct FirstPoint: Decodable {
    let timestamp: Double
    let price: Decimal
  }

  private struct FirstResponse: Decodable {
    let coins: [String: FirstPoint]
  }

  // MARK: - Parsers

  /// A fresh UTC `.withFullDate` formatter. `ISO8601DateFormatter` (an
  /// `NSFormatter`) is not safe for concurrent `string(from:)`, and the price
  /// chain fans out over tokens concurrently, so each call allocates its own
  /// rather than sharing one (matches `CoinGeckoClient.parseMarketChartResponse`).
  private static func makeDayFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }

  /// Single-coin `/chart` → `[ISO-day: USD]`, keeping the last point per UTC
  /// day. The whole coin is dropped when its confidence is below `floor`.
  static func parseChart(_ data: Data, confidenceFloor: Decimal) throws -> [String: Decimal] {
    let response = try JSONDecoder().decode(ChartResponse.self, from: data)
    let dayFormatter = makeDayFormatter()
    var result: [String: Decimal] = [:]
    for coin in response.coins.values {
      if let confidence = coin.confidence, confidence < confidenceFloor { continue }
      for point in coin.prices {
        let day = dayFormatter.string(from: Date(timeIntervalSince1970: point.timestamp))
        result[day] = point.price  // later points overwrite earlier same-day points
      }
    }
    return result
  }

  /// `/prices/current` → `[coinId: USD]`, dropping coins below `floor`.
  static func parseCurrent(_ data: Data, confidenceFloor: Decimal) throws -> [String: Decimal] {
    let response = try JSONDecoder().decode(CurrentResponse.self, from: data)
    var result: [String: Decimal] = [:]
    for (coinId, coin) in response.coins {
      if let confidence = coin.confidence, confidence < confidenceFloor { continue }
      result[coinId] = coin.price
    }
    return result
  }

  /// `/prices/first` → `[coinId: earliest point]`. No confidence gate: presence
  /// is the support signal; the floor is applied to live price fetches only.
  static func parseFirst(_ data: Data) throws -> [String: FirstPoint] {
    try JSONDecoder().decode(FirstResponse.self, from: data).coins
  }

  static func isoDay(from timestamp: Double) -> String {
    makeDayFormatter().string(from: Date(timeIntervalSince1970: timestamp))
  }
}

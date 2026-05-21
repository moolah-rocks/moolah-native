import Foundation

/// Yahoo Finance `/v1/finance/search` name-search adapter.
///
/// Filters the raw `quotes` array to `EQUITY ∪ ETF ∪ MUTUALFUND` and
/// trims whitespace from `shortname` (Yahoo pads many names with
/// trailing spaces). Falls back to `longname` then `symbol` when
/// `shortname` is missing or empty after trimming.
struct YahooFinanceStockSearchClient: StockSearchClient {
  private let http: RateLimitedHTTPClient
  private static let baseURL: URL = {
    guard let url = URL(string: "https://query1.finance.yahoo.com/v1/finance/search")
    else { preconditionFailure("malformed Yahoo search URL — fix the literal") }
    return url
  }()

  init(http: RateLimitedHTTPClient) {
    self.http = http
  }

  func search(query: String) async throws -> [StockSearchHit] {
    var components = URLComponents(url: Self.baseURL, resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "q", value: query),
      URLQueryItem(name: "quotesCount", value: "20"),
      URLQueryItem(name: "newsCount", value: "0"),
    ]
    guard let url = components?.url else { throw URLError(.badURL) }

    var request = URLRequest(url: url)
    request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

    let (data, _) = try await http.data(for: request)
    let decoded = try JSONDecoder().decode(Wire.self, from: data)
    return decoded.quotes.compactMap { wire in
      guard let quoteType = QuoteType(rawValue: wire.quoteType) else { return nil }
      let trimmedShort = wire.shortname?.trimmingCharacters(in: .whitespacesAndNewlines)
      let trimmedLong = wire.longname?.trimmingCharacters(in: .whitespacesAndNewlines)
      let displayName: String
      if let short = trimmedShort, !short.isEmpty {
        displayName = short
      } else if let long = trimmedLong, !long.isEmpty {
        displayName = long
      } else {
        displayName = wire.symbol
      }
      return StockSearchHit(
        symbol: wire.symbol,
        name: displayName,
        exchange: wire.exchange,
        quoteType: quoteType
      )
    }
  }
}

private struct Wire: Decodable {
  let quotes: [WireQuote]
}

private struct WireQuote: Decodable {
  let symbol: String
  let shortname: String?
  let longname: String?
  let exchange: String
  let quoteType: String
}

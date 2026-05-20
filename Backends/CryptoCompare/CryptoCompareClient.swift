// Backends/CryptoCompare/CryptoCompareClient.swift
import Foundation

struct CryptoCompareClient: CryptoPriceClient, Sendable {
  var syncProvider: SyncProvider { .cryptoCompare }

  private static let baseURL =
    URL(string: "https://min-api.cryptocompare.com") ?? URL(fileURLWithPath: "/")
  private let session: URLSession
  private let rateLimitGate: RateLimitGate
  private let failureCache: FailedRequestCache

  init(
    session: URLSession = .shared,
    rateLimitGate: RateLimitGate = RateLimitGate(),
    failureCache: FailedRequestCache = FailedRequestCache()
  ) {
    self.session = session
    self.rateLimitGate = rateLimitGate
    self.failureCache = failureCache
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
    guard let symbol = mapping.cryptocompareSymbol else {
      throw CryptoPriceError.noProviderMapping(
        tokenId: mapping.instrumentId, provider: "CryptoCompare")
    }
    let url = Self.histodayURL(symbol: symbol, from: range.lowerBound, to: range.upperBound)
    let (data, response) = try await session.dataRespectingRateLimit(
      for: URLRequest(url: url), gate: rateLimitGate, failureCache: failureCache)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return try Self.parseHistodayResponse(data)
  }

  func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal] {
    let symbolToMapping = Dictionary(
      mappings.compactMap { mapping -> (String, CryptoProviderMapping)? in
        guard let sym = mapping.cryptocompareSymbol else { return nil }
        return (sym, mapping)
      },
      uniquingKeysWith: { first, _ in first }
    )
    guard !symbolToMapping.isEmpty else { return [:] }

    let url = Self.priceMultiURL(symbols: Array(symbolToMapping.keys))
    let (data, response) = try await session.dataRespectingRateLimit(
      for: URLRequest(url: url), gate: rateLimitGate, failureCache: failureCache)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    let symbolPrices = try Self.parsePriceMultiResponse(data)

    var result: [String: Decimal] = [:]
    for (symbol, price) in symbolPrices {
      if let mapping = symbolToMapping[symbol] {
        result[mapping.instrumentId] = price
      }
    }
    return result
  }

  // MARK: - URL builders (internal for testing)

  static func histodayURL(symbol: String, from: Date, to: Date) -> URL {
    let calendar = Calendar(identifier: .gregorian)
    let days = max(0, calendar.dateComponents([.day], from: from, to: to).day ?? 0)
    let toTimestamp = Int(to.timeIntervalSince1970)
    let pathURL = baseURL.appendingPathComponent("/data/v2/histoday")
    var components =
      URLComponents(url: pathURL, resolvingAgainstBaseURL: false) ?? URLComponents()
    components.queryItems = [
      URLQueryItem(name: "fsym", value: symbol),
      URLQueryItem(name: "tsym", value: "USD"),
      URLQueryItem(name: "limit", value: String(days)),
      URLQueryItem(name: "toTs", value: String(toTimestamp)),
    ]
    return components.url ?? pathURL
  }

  static func coinListURL() -> URL {
    let pathURL = baseURL.appendingPathComponent("/data/all/coinlist")
    var components =
      URLComponents(url: pathURL, resolvingAgainstBaseURL: false) ?? URLComponents()
    components.queryItems = [
      URLQueryItem(name: "summary", value: "true")
    ]
    return components.url ?? pathURL
  }

  static func priceMultiURL(symbols: [String]) -> URL {
    let pathURL = baseURL.appendingPathComponent("/data/pricemulti")
    var components =
      URLComponents(url: pathURL, resolvingAgainstBaseURL: false) ?? URLComponents()
    components.queryItems = [
      URLQueryItem(name: "fsyms", value: symbols.joined(separator: ",")),
      URLQueryItem(name: "tsyms", value: "USD"),
    ]
    return components.url ?? pathURL
  }

  // MARK: - Response parsers (internal for testing)

  static func parseHistodayResponse(_ data: Data) throws -> [String: Decimal] {
    let container = try JSONDecoder().decode(HistodayContainer.self, from: data)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    var result: [String: Decimal] = [:]
    for entry in container.Data.Data {
      let date = Date(timeIntervalSince1970: TimeInterval(entry.time))
      let key = formatter.string(from: date)
      result[key] = entry.close
    }
    return result
  }

  /// Parses the coin list response and builds a reverse index: lowercased contract address → symbol.
  /// Entries with "N/A", empty, or absent contract addresses are excluded.
  static func parseCoinListResponse(_ data: Data) throws -> [String: String] {
    let container = try JSONDecoder().decode(CoinListContainer.self, from: data)
    var index: [String: String] = [:]
    for coin in container.entries.values {
      guard let addr = coin.smartContractAddress, addr != "N/A", !addr.isEmpty else { continue }
      index[addr.lowercased()] = coin.symbol
    }
    return index
  }

  /// Parses the coin list to find symbols that have no smart contract address (native tokens).
  static func parseNativeSymbols(_ data: Data) throws -> Set<String> {
    let container = try JSONDecoder().decode(CoinListContainer.self, from: data)
    var symbols: Set<String> = []
    for coin in container.entries.values {
      let addr = coin.smartContractAddress ?? ""
      if addr == "N/A" || addr.isEmpty {
        symbols.insert(coin.symbol)
      }
    }
    return symbols
  }

  /// Returns the set of every symbol present in the coin list, regardless
  /// of whether the entry carries a smart-contract address. Used by the
  /// post-confirm path in `CompositeTokenResolutionClient`: once a
  /// contract-based provider (CoinGecko) has verified that
  /// `(chainId, contractAddress) → symbol`, the resolver checks this set
  /// to authorise a CryptoCompare by-symbol fallback. Catches the case
  /// where CryptoCompare's catalog has the symbol (e.g. USDT) but its
  /// entry doesn't pin a specific contract — so the contract-address
  /// index alone doesn't surface it.
  static func parseCoinSymbols(_ data: Data) throws -> Set<String> {
    let container = try JSONDecoder().decode(CoinListContainer.self, from: data)
    var symbols: Set<String> = []
    for coin in container.entries.values {
      symbols.insert(coin.symbol)
    }
    return symbols
  }

  static func parsePriceMultiResponse(_ data: Data) throws -> [String: Decimal] {
    let raw = try JSONDecoder().decode([String: [String: Decimal]].self, from: data)
    var result: [String: Decimal] = [:]
    for (symbol, currencies) in raw {
      if let usd = currencies["USD"] {
        result[symbol] = usd
      }
    }
    return result
  }

  private static func dateString(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return formatter.string(from: date)
  }
}

// MARK: - Response types

/// Decoded per-entry rather than as `[String: CoinListEntry]` because
/// CryptoCompare's coin list occasionally ships rows with missing fields
/// (e.g. an `MLS` entry missing `CoinName`). An atomic decode would throw
/// on the first bad row and break token resolution for every crypto.
private struct CoinListContainer: Decodable {
  let entries: [String: CoinListEntry]

  init(from decoder: Decoder) throws {
    let outer = try decoder.container(keyedBy: OuterKey.self)
    var collected: [String: CoinListEntry] = [:]
    if let inner = try? outer.nestedContainer(keyedBy: DynamicKey.self, forKey: .data) {
      for key in inner.allKeys {
        guard let entry = try? inner.decode(CoinListEntry.self, forKey: key) else { continue }
        collected[key.stringValue] = entry
      }
    }
    self.entries = collected
  }

  private enum OuterKey: String, CodingKey {
    case data = "Data"
  }

  private struct DynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
      self.stringValue = stringValue
      self.intValue = nil
    }

    init?(intValue: Int) {
      self.stringValue = String(intValue)
      self.intValue = intValue
    }
  }
}

private struct CoinListEntry: Decodable {
  let symbol: String
  /// Optional because CryptoCompare's primary stablecoin entries
  /// (USDT, USDC, DAI, …) ship without this field — the listing is
  /// chain-agnostic. Treating it as a required `String` made the entry's
  /// decode fail and the surrounding per-entry `try?` silently dropped
  /// it, so post-confirm symbol-based pricing couldn't find USDT in the
  /// catalog at all.
  let smartContractAddress: String?

  private enum CodingKeys: String, CodingKey {
    case symbol = "Symbol"
    case smartContractAddress = "SmartContractAddress"
  }
}

private struct HistodayContainer: Decodable {
  let Data: HistodayData  // swiftlint:disable:this identifier_name
}

private struct HistodayData: Decodable {
  let Data: [HistodayEntry]  // swiftlint:disable:this identifier_name
}

private struct HistodayEntry: Decodable {
  let time: Int
  let close: Decimal
}

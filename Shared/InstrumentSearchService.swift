import Foundation
import OSLog

struct InstrumentSearchService: Sendable {
  private let registry: any InstrumentRegistryRepository
  private let catalog: (any CoinGeckoCatalog)?
  private let resolutionClient: any TokenResolutionClient
  private let stockSearchClient: any StockSearchClient
  private let logger = Logger(
    subsystem: "com.moolah.app",
    category: "InstrumentSearch"
  )

  init(
    registry: any InstrumentRegistryRepository,
    catalog: (any CoinGeckoCatalog)?,
    resolutionClient: any TokenResolutionClient,
    stockSearchClient: any StockSearchClient
  ) {
    self.registry = registry
    self.catalog = catalog
    self.resolutionClient = resolutionClient
    self.stockSearchClient = stockSearchClient
  }

  func search(
    query: String,
    kinds: Set<Instrument.Kind> = Set(Instrument.Kind.allCases)
  ) async -> [InstrumentSearchResult] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    let registered = await loadRegisteredOrLog()
    let cryptoRegistrations = await loadCryptoRegistrationsOrLog()
    let filteredRegistered = registered.filter { kinds.contains($0.kind) }
    if trimmed.isEmpty {
      return filteredRegistered.map {
        InstrumentSearchResult(
          instrument: $0,
          cryptoMapping: nil,
          isRegistered: true,
          requiresResolution: false
        )
      }
    }

    async let fiatResults: [InstrumentSearchResult] =
      kinds.contains(.fiatCurrency) ? fiatMatches(query: trimmed) : []
    async let cryptoResults: [InstrumentSearchResult] =
      kinds.contains(.cryptoToken)
      ? cryptoMatches(
        query: trimmed, registered: registered, mappings: cryptoRegistrations) : []
    async let stockResults: [InstrumentSearchResult] =
      kinds.contains(.stock) ? stockMatches(query: trimmed, registered: registered) : []

    let provider = await (fiatResults + cryptoResults + stockResults)
    let registeredMatches = registeredMatches(
      query: trimmed, all: filteredRegistered, cryptoMappings: cryptoRegistrations)
    let merged = merge(registered: registeredMatches, provider: provider)
    return rank(merged, query: trimmed)
  }

  private func loadRegisteredOrLog() async -> [Instrument] {
    do {
      return try await registry.all()
    } catch {
      logger.warning(
        "Registry fetch failed; returning empty registered set: \(error, privacy: .public)"
      )
      return []
    }
  }

  private func loadCryptoRegistrationsOrLog() async -> [CryptoRegistration] {
    do {
      return try await registry.allCryptoRegistrations()
    } catch {
      logger.warning(
        "Registry crypto registrations fetch failed: \(error, privacy: .public)"
      )
      return []
    }
  }

  // MARK: - Fiat

  /// Fiat-currency search path.
  ///
  /// Every fiat result is marked `isRegistered: true` by design (see the design
  /// spec §2.1): fiat is ambient — the full ISO currency set from
  /// `Locale.Currency.isoCurrencies` is always available without any registration
  /// step. From a picker's perspective "already in registry" is the correct
  /// affordance for fiat: no "Add" button should appear. Stock/crypto hits, in
  /// contrast, default `isRegistered: false` until they're promoted by the
  /// merge step when they share an id with a stored row.
  private func fiatMatches(query: String) -> [InstrumentSearchResult] {
    let lowered = query.lowercased()
    return Locale.Currency.isoCurrencies.compactMap { currency in
      let code = currency.identifier
      let lowerCode = code.lowercased()
      let localizedName =
        Locale.current.localizedString(forCurrencyCode: code)?.lowercased() ?? ""
      guard lowerCode.hasPrefix(lowered) || localizedName.contains(lowered)
      else { return nil }
      return InstrumentSearchResult(
        instrument: Instrument.fiat(code: code),
        cryptoMapping: nil,
        isRegistered: true,
        requiresResolution: false
      )
    }
  }

  // MARK: - Crypto

  /// Crypto search path.
  ///
  /// Routes through the local CoinGecko `CatalogEntry` snapshot rather than a
  /// live network search. Each catalogue entry maps to one synthetic
  /// `Instrument` keyed on `(chainId, contractAddress)`. Hits whose id already
  /// exists in the registry are dropped here — the merge step replaces them
  /// with the registered row, which carries the persisted `CryptoProviderMapping`.
  ///
  /// `requiresResolution: true` signals to the picker that this row must call
  /// `TokenResolutionClient.resolve(...)` before it can be persisted (decimals
  /// and the cryptocompare/binance ids are resolved at registration time).
  ///
  /// When `catalog` is `nil` (e.g. catalog init failed), this returns
  /// the empty list — crypto search degrades to the registry/Yahoo paths only.
  private func cryptoMatches(
    query: String,
    registered: [Instrument],
    mappings: [CryptoRegistration]
  ) async -> [InstrumentSearchResult] {
    if isContractAddress(query) {
      return await cryptoContractLookup(address: query)
    }
    guard let catalog else { return [] }
    let entries = await catalog.search(query: query, limit: 20)
    return entries.map { entry in
      let placeholder = makePlaceholderCryptoInstrument(from: entry)
      if let registration = mappings.first(where: { $0.id == placeholder.id }) {
        return InstrumentSearchResult(
          instrument: registration.instrument,
          cryptoMapping: registration.mapping,
          isRegistered: true,
          requiresResolution: false
        )
      }
      return InstrumentSearchResult(
        instrument: placeholder,
        cryptoMapping: nil,
        isRegistered: mappings.contains { $0.instrument.id == placeholder.id },
        requiresResolution: true
      )
    }
  }

  /// Builds the synthetic `Instrument` for an unregistered catalog hit. The
  /// `decimals` value is a placeholder (18 for EVM-style platforms, 8 for
  /// platformless natives — both are the most common values for their
  /// classes). Resolution at registration time replaces it with the real
  /// decimals from the price provider.
  private func makePlaceholderCryptoInstrument(from entry: CatalogEntry) -> Instrument {
    if let platform = entry.preferredPlatform, let chainId = platform.chainId {
      return Instrument.crypto(
        chainId: chainId,
        contractAddress: platform.contractAddress,
        symbol: entry.symbol,
        name: entry.name,
        decimals: 18
      )
    }
    return Instrument.crypto(
      chainId: 0,
      contractAddress: nil,
      symbol: entry.symbol,
      name: entry.name,
      decimals: 8
    )
  }

  private func cryptoContractLookup(address: String) async -> [InstrumentSearchResult] {
    do {
      // chainId 1 (Ethereum mainnet) is the most common; the follow-up UI
      // can expose a chain selector later.
      let result = try await resolutionClient.resolve(
        chainId: 1,
        contractAddress: address,
        symbol: nil,
        isNative: false
      )
      guard let coingeckoId = result.coingeckoId,
        let symbol = result.resolvedSymbol,
        let name = result.resolvedName,
        let decimals = result.resolvedDecimals
      else { return [] }
      let instrument = Instrument.crypto(
        chainId: 1,
        contractAddress: address,
        symbol: symbol,
        name: name,
        decimals: decimals
      )
      let mapping = CryptoProviderMapping(
        instrumentId: instrument.id,
        coingeckoId: coingeckoId,
        cryptocompareSymbol: result.cryptocompareSymbol,
        binanceSymbol: result.binanceSymbol
      )
      return [
        InstrumentSearchResult(
          instrument: instrument,
          cryptoMapping: mapping,
          isRegistered: false,
          requiresResolution: false
        )
      ]
    } catch {
      logger.warning(
        "Contract resolve failed for address=\(address, privacy: .public): \(error, privacy: .public)"
      )
      return []
    }
  }

  private func isContractAddress(_ query: String) -> Bool {
    guard query.count == 42 else { return false }
    guard query.hasPrefix("0x") else { return false }
    let hexPart = query.dropFirst(2)
    return hexPart.allSatisfy { $0.isHexDigit }
  }

  // MARK: - Stock

  /// Stock search path.
  ///
  /// Routes through `StockSearchClient` (Yahoo Finance `/v1/finance/search`).
  /// Each hit maps to a synthetic `Instrument` keyed on `"\(exchange):\(ticker)"`.
  /// Hits whose id already exists in the registry are marked `isRegistered: true`
  /// so the picker doesn't redundantly offer to register them; the merge step
  /// then replaces the synthetic row with the persisted one.
  private func stockMatches(
    query: String, registered: [Instrument]
  ) async -> [InstrumentSearchResult] {
    do {
      let hits = try await stockSearchClient.search(query: query)
      return hits.map { hit in
        let instrument = Instrument.stock(
          ticker: hit.symbol, exchange: hit.exchange, name: hit.name)
        let isRegistered = registered.contains { $0.id == instrument.id }
        return InstrumentSearchResult(
          instrument: instrument,
          cryptoMapping: nil,
          isRegistered: isRegistered,
          requiresResolution: !isRegistered
        )
      }
    } catch {
      logger.warning(
        "Stock search failed for query=\(query, privacy: .public): \(error, privacy: .public)"
      )
      return []
    }
  }

  // MARK: - Merge + rank

  private func registeredMatches(
    query: String,
    all: [Instrument],
    cryptoMappings: [CryptoRegistration]
  ) -> [InstrumentSearchResult] {
    let lowered = query.lowercased()
    let mappingsById = Dictionary(
      uniqueKeysWithValues: cryptoMappings.map { ($0.instrument.id, $0.mapping) })
    return all.compactMap { instrument in
      let id = instrument.id.lowercased()
      let ticker = instrument.ticker?.lowercased() ?? ""
      let name = instrument.name.lowercased()
      guard id.contains(lowered) || ticker.contains(lowered) || name.contains(lowered)
      else { return nil }
      return InstrumentSearchResult(
        instrument: instrument,
        cryptoMapping: mappingsById[instrument.id],
        isRegistered: true,
        requiresResolution: false
      )
    }
  }

  private func merge(
    registered: [InstrumentSearchResult],
    provider: [InstrumentSearchResult]
  ) -> [InstrumentSearchResult] {
    var seen = Set<String>()
    var out: [InstrumentSearchResult] = []
    for result in registered where seen.insert(result.id).inserted {
      out.append(result)
    }
    for result in provider where seen.insert(result.id).inserted {
      out.append(result)
    }
    return out
  }
}

// MARK: - Ranking

extension InstrumentSearchService {
  /// Orders the merged results by relevance. The primary signal is an exact
  /// ticker/code match against the query — typing "USD" puts US Dollar first;
  /// the secondary signal favours fiat currencies over every other kind so
  /// currency matches lead crypto tokens. Within a bucket the merge order is
  /// preserved (registered rows already lead their provider counterparts), so
  /// the original index is the final, stability-preserving tiebreaker.
  private func rank(
    _ results: [InstrumentSearchResult],
    query: String
  ) -> [InstrumentSearchResult] {
    let lowered = query.lowercased()
    return
      results
      .enumerated()
      .sorted { lhs, rhs in
        RankKey(lhs.element, lowered: lowered, index: lhs.offset)
          < RankKey(rhs.element, lowered: lowered, index: rhs.offset)
      }
      .map(\.element)
  }

  /// Sort key for a single search result. Lower values rank earlier: exact
  /// ticker/code matches before inexact ones, fiat currencies before every
  /// other kind, and the original merge index as a stable final tiebreaker.
  private struct RankKey: Comparable {
    let exactRank: Int
    let kindRank: Int
    let index: Int

    init(_ result: InstrumentSearchResult, lowered: String, index: Int) {
      let instrument = result.instrument
      let isExact =
        instrument.id.lowercased() == lowered
        || instrument.ticker?.lowercased() == lowered
      self.exactRank = isExact ? 0 : 1
      self.kindRank = instrument.kind == .fiatCurrency ? 0 : 1
      self.index = index
    }

    static func < (lhs: RankKey, rhs: RankKey) -> Bool {
      (lhs.exactRank, lhs.kindRank, lhs.index)
        < (rhs.exactRank, rhs.kindRank, rhs.index)
    }
  }
}

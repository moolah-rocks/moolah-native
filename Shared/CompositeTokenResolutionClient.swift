import Foundation

/// Production token resolution client that queries CryptoCompare, Binance, and optionally CoinGecko
/// to populate provider-specific identifiers for a token.
struct CompositeTokenResolutionClient: TokenResolutionClient, Sendable {
  private let networking: NetworkingServices
  /// Resolves the CoinGecko key per request (not once at construction) so a
  /// Pro key entered in Settings flips contract-lookup and asset-platforms
  /// calls from the free public host to the Pro host on the next resolution
  /// without rebuilding the client. An empty key (the default) still queries
  /// the free public host — the CoinGecko step is best-effort, never gated
  /// off by an empty key.
  private let coinGeckoApiKeyProvider: @Sendable () -> String?
  /// Offline `(chainId, contract) → CoinGecko id` source, consulted before any
  /// network provider so a token already known to the bundled / cached catalog
  /// is priced immediately. `nil` disables the local-first path (e.g. tests).
  private let localResolver: LocalContractResolver?

  // For testing: inject pre-parsed reference data
  private let preloadedCoinList: Data?
  private let preloadedExchangeInfo: Data?

  init(
    networking: NetworkingServices,
    coinGeckoApiKeyProvider: @Sendable @escaping () -> String? = { nil },
    localResolver: LocalContractResolver? = nil
  ) {
    self.networking = networking
    self.coinGeckoApiKeyProvider = coinGeckoApiKeyProvider
    self.localResolver = localResolver
    self.preloadedCoinList = nil
    self.preloadedExchangeInfo = nil
  }

  /// Test initializer with pre-loaded reference data. Accepts an optional
  /// `networking` so tests that exercise the CoinGecko-dependent paths can
  /// plug a `StubURLProtocol`-backed `NetworkingServices` in.
  init(
    coinListData: Data,
    exchangeInfoData: Data,
    coinGeckoApiKeyProvider: @Sendable @escaping () -> String?,
    networking: NetworkingServices = NetworkingServices(),
    localResolver: LocalContractResolver? = nil
  ) {
    self.networking = networking
    self.coinGeckoApiKeyProvider = coinGeckoApiKeyProvider
    self.localResolver = localResolver
    self.preloadedCoinList = coinListData
    self.preloadedExchangeInfo = exchangeInfoData
  }

  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult {
    var result = TokenResolutionResult()

    // Local-first: a contract-addressed token already known to the bundled /
    // cached catalog is priced from local data, short-circuiting ahead of any
    // network provider call. Natives are identified by symbol below, not by
    // contract, so they skip this path. The discovery service persists the
    // on-chain instrument (correct decimals), so only the provider id is
    // needed here.
    if !isNative, let contractAddress,
      let local = await localResolver?.localContractMatch(
        chainId: chainId, contractAddress: contractAddress)
    {
      result.coingeckoId = local.coingeckoId
      result.resolvedSymbol = local.symbol
      result.resolvedName = local.name
      return result
    }

    let coinListData = try await fetchCoinListData()

    resolveFromCryptoCompare(
      coinListData: coinListData,
      contractAddress: contractAddress,
      symbol: symbol,
      isNative: isNative,
      result: &result)

    if !isNative, let contractAddress {
      await resolveFromCoinGecko(
        chainId: chainId, contractAddress: contractAddress, result: &result)
    }

    postConfirmCryptoCompareBySymbol(
      coinListData: coinListData, isNative: isNative, result: &result)

    try await resolveBinancePair(
      inputSymbol: symbol, isNative: isNative, result: &result)

    return result
  }

  // MARK: - Provider steps

  /// Step 1: CryptoCompare's coin list — natives match by symbol; ERC-20s
  /// match only by `(chainId, contractAddress)`. The user-supplied ticker
  /// is untrusted for ERC-20s (a spam contract can claim any ticker), so
  /// a ticker-only fallback is intentionally excluded here.
  private func resolveFromCryptoCompare(
    coinListData: Data,
    contractAddress: String?,
    symbol: String?,
    isNative: Bool,
    result: inout TokenResolutionResult
  ) {
    if isNative, let symbol {
      let nativeSymbols = (try? CryptoCompareClient.parseNativeSymbols(coinListData)) ?? []
      if nativeSymbols.contains(symbol.uppercased()) {
        result.cryptocompareSymbol = symbol.uppercased()
        result.resolvedSymbol = symbol.uppercased()
      }
    } else if let contractAddress {
      let index = (try? CryptoCompareClient.parseCoinListResponse(coinListData)) ?? [:]
      if let ccSymbol = index[contractAddress.lowercased()] {
        result.cryptocompareSymbol = ccSymbol
        result.resolvedSymbol = ccSymbol
      }
    }
  }

  /// Step 2: CoinGecko contract-based lookup (ERC-20s only). Runs before
  /// Binance so a CG-confirmed symbol can authorise the Binance pair
  /// attribution (#790). An empty key (`""`) falls through to the free
  /// public CoinGecko endpoint so users without a Pro key still get tokens
  /// like USDC priced; a configured key targets the Pro host. A provider
  /// returning `nil` opts out of CoinGecko entirely so tests that don't stub
  /// the network don't reach for it. The live factories pass a provider that
  /// coalesces a missing keychain entry to `""`, so production always runs
  /// the free-tier path. Resolution is best-effort — any error is swallowed.
  private func resolveFromCoinGecko(
    chainId: Int, contractAddress: String, result: inout TokenResolutionResult
  ) async {
    guard let apiKey = coinGeckoApiKeyProvider() else { return }
    do {
      let platformMapping = try await fetchAssetPlatforms(apiKey: apiKey)
      guard let platformSlug = platformMapping[chainId] else { return }
      let url = CoinGeckoClient.contractLookupURL(
        platformId: platformSlug, contractAddress: contractAddress, apiKey: apiKey)
      let host = apiKey.isEmpty ? "api.coingecko.com" : "pro-api.coingecko.com"
      let http = networking.client(forHost: host)
      let (data, _) = try await http.data(for: URLRequest(url: url))
      let lookup = try CoinGeckoClient.parseContractLookupResponse(data)
      result.coingeckoId = lookup.id
      result.resolvedName = lookup.name
      result.resolvedSymbol = result.resolvedSymbol ?? lookup.symbol.uppercased()
      result.resolvedDecimals = lookup.decimals
    } catch {
      // CoinGecko resolution is best-effort.
    }
  }

  /// Step 2b: CryptoCompare post-confirm by symbol. The contract-address
  /// index (step 1) misses stablecoins like USDT/USDC/DAI whose
  /// CryptoCompare entries are chain-agnostic primary listings with no
  /// `SmartContractAddress` field. Once CoinGecko has verified
  /// `(chainId, contractAddress) → resolvedSymbol`, attempt a by-symbol
  /// match against the same coin list. Safe re #790: a spam ERC-20
  /// whose ticker collides with a legit token's never reaches this
  /// branch because CoinGecko's contract lookup would not have set
  /// `result.resolvedSymbol` for the spam contract.
  private func postConfirmCryptoCompareBySymbol(
    coinListData: Data, isNative: Bool, result: inout TokenResolutionResult
  ) {
    guard !isNative, result.cryptocompareSymbol == nil,
      let confirmedSymbol = result.resolvedSymbol
    else { return }
    let symbols = (try? CryptoCompareClient.parseCoinSymbols(coinListData)) ?? []
    if symbols.contains(confirmedSymbol) {
      result.cryptocompareSymbol = confirmedSymbol
    }
  }

  /// Step 3: Binance exchange info. Binance has no notion of `(chainId,
  /// contractAddress)`, so for ERC-20s we only attempt the lookup when a
  /// contract-based provider (CryptoCompare or CoinGecko) has already
  /// confirmed the symbol's identity for this exact contract. Without
  /// that gate, a spam ERC-20 with a copied ticker inherits the
  /// legitimate token's `<TICKER>USDT` mapping and poisons the running
  /// balance — see #790. Native tokens may fall back to the input symbol
  /// because `(chainId, isNative)` already pins identity.
  private func resolveBinancePair(
    inputSymbol: String?, isNative: Bool, result: inout TokenResolutionResult
  ) async throws {
    let pairSymbolBase: String? =
      isNative ? (result.resolvedSymbol ?? inputSymbol) : result.resolvedSymbol
    guard let baseSymbol = pairSymbolBase?.uppercased(), !baseSymbol.isEmpty
    else { return }
    let exchangeInfoData = try await fetchExchangeInfoData()
    let pairs = try BinanceClient.parseExchangeInfoResponse(exchangeInfoData)
    let candidate = "\(baseSymbol)USDT"
    if pairs.contains(candidate) {
      result.binanceSymbol = candidate
    }
  }

  // MARK: - Reference data fetching

  private func fetchCoinListData() async throws -> Data {
    if let preloaded = preloadedCoinList { return preloaded }
    let url = CryptoCompareClient.coinListURL()
    let http = networking.client(forHost: "min-api.cryptocompare.com")
    let (data, _) = try await http.data(for: URLRequest(url: url))
    return data
  }

  private func fetchExchangeInfoData() async throws -> Data {
    if let preloaded = preloadedExchangeInfo { return preloaded }
    let url = BinanceClient.exchangeInfoURL()
    let http = networking.client(forHost: "api.binance.com")
    let (data, _) = try await http.data(for: URLRequest(url: url))
    return data
  }

  private func fetchAssetPlatforms(apiKey: String) async throws -> [Int: String] {
    let url = CoinGeckoClient.assetPlatformsURL(apiKey: apiKey)
    let host = apiKey.isEmpty ? "api.coingecko.com" : "pro-api.coingecko.com"
    let http = networking.client(forHost: host)
    let (data, _) = try await http.data(for: URLRequest(url: url))
    return try CoinGeckoClient.parseAssetPlatformsResponse(data)
  }
}

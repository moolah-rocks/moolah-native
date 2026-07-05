import Foundation

/// The cache-query seams that the re-detection pass reads, bundled so they
/// can be passed as one value and stubbed in tests. Each field is a
/// protocol, so the back-end provider caches and the test stubs both
/// conform without the domain layer depending on any concrete type (#1140).
struct ProviderCatalogLookups: Sendable {
  let binance: any BinancePairLookup
  /// `nil` when no local CoinGecko contract catalog is available (e.g. the
  /// bundled snapshot has not loaded yet). The reconcile pass skips
  /// CoinGecko id detection in that case.
  let coinGecko: (any LocalContractResolver)?
}

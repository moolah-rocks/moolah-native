import Foundation

/// A provider catalog whose contents can be refreshed from the network on a
/// staleness schedule. Conformers (CoinGecko, CryptoCompare, Binance) own a
/// `CatalogDatabase` and delegate the conditional-GET / ETag / `last_fetched`
/// loop to `CatalogRefresh`.
///
/// `refreshIfStale()` is non-throwing by contract: the catalog degrades to its
/// last good snapshot rather than surfacing network failures to the UI.
protocol RefreshableCatalog: Sendable {
  func refreshIfStale() async
}

/// One conditional-GET endpoint in a catalog refresh. `key` doubles as the
/// `etag` table key and as the key under which the fetched body is handed back
/// to the provider's `apply` closure.
struct CatalogEndpoint: Sendable {
  let key: String
  let url: URL
}

/// The outcome of one conditional GET. `.ok` carries the fresh body plus the
/// server's new ETag (if any); `.notModified` is a 304 — the stored snapshot
/// is still current.
enum CatalogFetchOutcome: Sendable {
  case ok(Data, etag: String?)
  case notModified
}

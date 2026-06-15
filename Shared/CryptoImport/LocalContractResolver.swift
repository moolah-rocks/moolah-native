import Foundation

/// A token's identity resolved offline from the bundled / cached CoinGecko
/// catalog by its on-chain `(chainId, contractAddress)`. Carries just enough
/// to mark a discovered token `.priced` without a network round-trip: the
/// persisted instrument keeps its on-chain decimals (the discovery service
/// builds it), so only the provider id is needed here.
struct LocalContractMatch: Sendable, Equatable {
  let coingeckoId: String
  let symbol: String
  let name: String
}

/// Offline `(chainId, contractAddress) → CoinGecko id` resolution. Lets the
/// token resolver price a known token from local data before falling back to
/// the network providers. `SQLiteCoinGeckoCatalog` is the production conformer.
protocol LocalContractResolver: Sendable {
  func localContractMatch(chainId: Int, contractAddress: String) async -> LocalContractMatch?
}

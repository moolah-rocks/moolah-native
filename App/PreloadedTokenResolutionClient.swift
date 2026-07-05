import Foundation

/// Deterministic `TokenResolutionClient` used in UI tests. Returns a
/// hard-coded `(coingeckoId, binanceSymbol)` pair for the matching
/// `(chainId, contractAddress)` and an empty result otherwise — so a row
/// that doesn't match the seed's expected token is not silently registered.
struct PreloadedTokenResolutionClient: TokenResolutionClient, Sendable {
  let chainId: Int
  let contractAddress: String
  let result: TokenResolutionResult

  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult {
    if chainId == self.chainId,
      let address = contractAddress,
      address.lowercased() == self.contractAddress.lowercased()
    {
      return result
    }
    return TokenResolutionResult()
  }
}

extension PreloadedTokenResolutionClient {
  /// The resolution stub installed for the `.cryptoCatalogPreloaded` seed.
  /// Matches the catalogue's single coin so a tap on the Uniswap row
  /// resolves with provider IDs populated and registration succeeds.
  static let cryptoCatalogPreloaded = PreloadedTokenResolutionClient(
    chainId: UITestFixtures.CryptoCatalogPreloaded.chainId,
    contractAddress: UITestFixtures.CryptoCatalogPreloaded.contractAddress,
    result: TokenResolutionResult(
      coingeckoId: UITestFixtures.CryptoCatalogPreloaded.coingeckoMappingId,
      binanceSymbol: UITestFixtures.CryptoCatalogPreloaded.binanceSymbol,
      resolvedName: UITestFixtures.CryptoCatalogPreloaded.name,
      resolvedSymbol: UITestFixtures.CryptoCatalogPreloaded.symbol,
      resolvedDecimals: 18
    )
  )
}

// Domain/Repositories/TokenResolutionClient.swift
import Foundation

/// Data needed to resolve a token from provider reference data.
struct TokenResolutionResult: Sendable {
  var coingeckoId: String?
  var binanceSymbol: String?
  var resolvedName: String?
  var resolvedSymbol: String?
  var resolvedDecimals: Int?
}

/// Resolves a token's provider-specific identifiers from reference data.
protocol TokenResolutionClient: Sendable {
  func resolve(
    chainId: Int, contractAddress: String?, symbol: String?, isNative: Bool
  ) async throws -> TokenResolutionResult
}

extension TokenResolutionResult {
  /// Whether at least one provider produced a usable identifier. The
  /// instrument-picker registers crypto only when this is `true`; otherwise
  /// the user sees "Could not find a price source for this token."
  var hasAnyProviderId: Bool {
    coingeckoId != nil || binanceSymbol != nil
  }
}

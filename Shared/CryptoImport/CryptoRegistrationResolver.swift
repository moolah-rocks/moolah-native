// Shared/CryptoImport/CryptoRegistrationResolver.swift
import Foundation

/// Narrow seam over `CryptoPriceService.resolveRegistration(...)` so the
/// `CryptoTokenDiscoveryService` actor can be unit-tested without spinning
/// up a real `CryptoPriceService` (which requires a `DatabaseWriter` and a
/// `TokenResolutionClient`). Production wires this to the live actor; tests
/// inject a counting / throwing stub.
protocol CryptoRegistrationResolver: Sendable {
  /// Resolves a token to a `CryptoRegistration` via the configured provider
  /// pipeline (CoinGecko by contract → Binance pair). Throws when no provider
  /// can identify the token; the discovery
  /// service treats a thrown error here as "no mapping" and proceeds to
  /// the spam / unpriced classification branches.
  func resolveRegistration(
    chainId: Int,
    contractAddress: String?,
    symbol: String?,
    isNative: Bool
  ) async throws -> CryptoRegistration
}

extension CryptoPriceService: CryptoRegistrationResolver {}

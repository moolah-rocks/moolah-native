import Foundation

/// CryptoCompare coin-list queries the token resolver needs, decoupled from the
/// concrete `CryptoCompareTokenCache` actor so the resolution client depends on
/// a seam rather than a backend type. The cache conforms directly — its actor
/// methods already match these signatures.
protocol CryptoCompareSymbolLookup: Sendable {
  /// The CryptoCompare symbol registered for the contract `address`, or `nil`.
  func symbol(forContract address: String) async -> String?
  /// Symbols listed without a contract address (native / chain-agnostic).
  func nativeSymbols() async -> Set<String>
  /// Every distinct symbol present in the cached coin list.
  func allSymbols() async -> Set<String>
}

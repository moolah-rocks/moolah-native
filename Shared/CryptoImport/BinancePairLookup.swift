import Foundation

/// Binance USDT-pair query the token resolver needs, decoupled from the
/// concrete `BinanceTokenCache` actor. The cache conforms directly — its actor
/// method already matches this signature.
protocol BinancePairLookup: Sendable {
  /// Whether Binance lists an active `<symbol>USDT` trading pair for `symbol`.
  func hasUsdtPair(base symbol: String) async -> Bool
}

// Shared/PriceSourceResolver.swift

import Foundation

/// Resolves a per-instrument `PriceSource` by dispatching on `Instrument.kind`.
/// `source(for:)` is non-throwing; a nil `cryptoPrices` is legal and is forwarded
/// to `CryptoPriceSource`, which defers the error to `quote(on:)`.
struct PriceSourceResolver: Sendable {
  private let stockPrices: StockPriceService
  private let cryptoPrices: CryptoPriceService?

  init(stockPrices: StockPriceService, cryptoPrices: CryptoPriceService?) {
    self.stockPrices = stockPrices
    self.cryptoPrices = cryptoPrices
  }

  func source(for instrument: Instrument) -> any PriceSource {
    switch instrument.kind {
    case .fiatCurrency:
      return FiatPriceSource(instrument: instrument)
    case .stock:
      return StockPriceSource(instrument: instrument, stockPrices: stockPrices)
    case .cryptoToken:
      return CryptoPriceSource(instrument: instrument, cryptoPrices: cryptoPrices)
    }
  }
}

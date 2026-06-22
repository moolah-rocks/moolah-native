// Shared/StockPriceSource.swift

import Foundation

/// `PriceSource` for stock instruments. Resolves the per-share close price and the
/// stock's listing currency via `StockPriceService`. Both are returned together
/// from `quote(on:)` because `instrument(for:)` requires an async hop.
struct StockPriceSource {
  let instrument: Instrument
  let stockPrices: StockPriceService
}

extension StockPriceSource: PriceSource {
  func quote(on date: Date) async throws -> (perUnit: Decimal, nativeQuote: Instrument) {
    guard let ticker = instrument.ticker else {
      throw ConversionError.unsupportedConversion(from: instrument.id, to: "fiat")
    }
    let price = try await stockPrices.price(ticker: ticker, on: date)
    let listing = try await stockPrices.instrument(for: ticker)
    return (perUnit: price, nativeQuote: listing)
  }

  func pricingStatus(on date: Date) async throws -> TokenPricingStatus {
    .priced
  }
}

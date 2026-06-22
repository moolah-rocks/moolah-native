import Foundation

/// `PriceSource` for fiat currency instruments. Fiat-to-fiat conversion is handled
/// by `ExchangeRateService` in the conversion layer; this source simply signals
/// that the instrument prices itself at 1 unit of itself.
struct FiatPriceSource {
  let instrument: Instrument
}

extension FiatPriceSource: PriceSource {
  func quote(on date: Date) async throws -> (perUnit: Decimal, nativeQuote: Instrument) {
    (perUnit: Decimal(1), nativeQuote: instrument)
  }

  func pricingStatus() async throws -> TokenPricingStatus {
    .priced
  }
}

import Foundation

/// `PriceSource` for crypto token instruments. Prices are denominated in USD;
/// `nativeQuote` is always `Instrument.USD`. `cryptoPrices` is optional to mirror
/// `FullConversionService`'s optional crypto service: when nil, `quote(on:)` throws
/// `ConversionError.noCryptoPriceService` and `pricingStatus()` returns `.priced`
/// (so requests proceed to the price call, where the error surfaces).
struct CryptoPriceSource {
  let instrument: Instrument
  let cryptoPrices: CryptoPriceService?
}

extension CryptoPriceSource: PriceSource {
  func quote(on date: Date) async throws -> (perUnit: Decimal, nativeQuote: Instrument) {
    guard let cryptoPrices else {
      throw ConversionError.noCryptoPriceService
    }
    let price = try await cryptoPrices.price(for: instrument, on: date)
    return (perUnit: price, nativeQuote: .USD)
  }

  /// Returns the registration's `pricingStatus` when a service is present.
  /// A missing registration (lookup returns nil, throwing `noProviderMapping`)
  /// returns `.priced` so the error surfaces later at price-fetch time — matching
  /// the existing `FullConversionService.convertResultDecision` behaviour where
  /// an absent registration falls through to `.convert` and throws at the provider call.
  /// When `cryptoPrices` is nil, returns `.priced` for the same reason.
  ///
  /// Every other error (registry / DB read failure, `CancellationError`)
  /// propagates rather than masquerading as `.priced` — it would otherwise be
  /// swallowed here and re-thrown indistinguishably at price time, hiding a real
  /// fault behind a `noProviderMapping`.
  func pricingStatus() async throws -> TokenPricingStatus {
    guard let cryptoPrices else { return .priced }
    do {
      return try await cryptoPrices.registration(for: instrument).pricingStatus
    } catch ConversionError.noProviderMapping {
      // Missing registration → proceed; price call will surface the error.
      return .priced
    }
  }
}

import Foundation

/// Per-instrument pricing resolver. A `PriceSource` knows how to fetch both the
/// unit price and the currency that price is denominated in for one instrument.
///
/// The `quote(on:)` method returns both at once so stock sources — whose listing
/// currency requires async I/O — can satisfy both without a separate sync property.
/// `pricingStatus()` lets callers short-circuit aggregation for tokens that are
/// intentionally valued at zero (`.unpriced`, `.spam`) without touching a price
/// provider.
protocol PriceSource: Sendable {
  /// Returns the per-unit price and the currency that price is denominated in.
  /// - For fiat: `(1, instrument)`.
  /// - For stock: `(closePrice, listingCurrency)`.
  /// - For crypto: `(usdPrice, .USD)`.
  func quote(on date: Date) async throws -> (perUnit: Decimal, nativeQuote: Instrument)

  /// Returns the pricing status for the instrument. For fiat and stock this is
  /// always `.priced`. For crypto it reflects the registration's
  /// `pricingStatus` — but a missing registration returns `.priced` rather than
  /// throwing, so the error surfaces later at price-fetch time; any other error
  /// (registry / DB failure, cancellation) propagates. Date-independent, so no
  /// `date` parameter — registration status does not vary by day.
  func pricingStatus() async throws -> TokenPricingStatus
}

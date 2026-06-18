// Shared/CryptoPriceService+PriceLookup.swift

import Foundation

// MARK: - Discriminated price lookup

// `priceLookup(for:on:)` honours `CryptoRegistration.pricingStatus` so
// `.unpriced` / `.spam` tokens resolve to `.knownZero` without invoking
// any provider, while a `.priced` registration goes through the
// `price(for:mapping:on:)` path and surfaces provider failure
// via `throw` (never collapsed to `.knownZero`).

extension CryptoPriceService {
  /// Discriminated price lookup. Honours `registration.pricingStatus`:
  /// - `.priced`   → `.priced(rate)` from the existing
  ///   `price(for:mapping:on:)` path.
  /// - `.unpriced` → `.knownZero` (no provider call).
  /// - `.spam`     → `.knownZero` (no provider call).
  ///
  /// Provider failure on a `.priced` registration still throws.
  ///
  /// Per `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11: this seam is
  /// the load-bearing fix that lets aggregation sites keep "intentional
  /// zero" distinct from "rate unavailable" for any total that aggregates
  /// crypto tokens.
  func priceLookup(
    for registration: CryptoRegistration,
    on date: Date
  ) async throws -> CryptoPriceLookup {
    switch registration.pricingStatus {
    case .unpriced, .spam:
      return .knownZero
    case .priced:
      do {
        let rate = try await price(
          for: registration.instrument,
          mapping: registration.mapping,
          on: date)
        return .priced(rate)
      } catch CryptoPriceError.beforeFirstTrade {
        // The token had no market price before its first confirmed trade date.
        // Return .knownZero so aggregation sites can value the holding as $0
        // (ATO-correct for pre-listing airdrops) rather than dropping the day.
        return .knownZero
      }
    }
  }
}

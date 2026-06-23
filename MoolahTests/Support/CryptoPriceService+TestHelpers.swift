import Foundation

@testable import Moolah

extension CryptoPriceService {
  /// Seeds a pre-built `CryptoPriceCache` into the actor's in-memory cache
  /// and marks the token as hydrated so `price(for:)` skips the SQL load.
  /// For use in unit tests only.
  func injectCacheForTesting(_ cache: CryptoPriceCache) {
    caches[cache.tokenId] = cache
    hydrated.insert(cache.tokenId)
  }
}

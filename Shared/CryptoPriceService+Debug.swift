// Shared/CryptoPriceService+Debug.swift

#if DEBUG
  import Foundation

  extension CryptoPriceService {
    /// Returns the largest gap (in calendar days) between consecutive price
    /// entries in the in-memory cache for `tokenId`. A gap of N means there
    /// are N − 1 un-fetched interior days between two adjacent data points.
    /// Used by contiguity tests to assert the bounded-window invariant.
    func debugMaxInteriorGapDays(tokenId: String) -> Int {
      caches[tokenId]?.prices.maxInteriorGapDays ?? 0
    }
  }
#endif

// Shared/ExchangeRateService+Debug.swift

#if DEBUG
  import Foundation

  extension ExchangeRateService {
    /// Returns the largest gap (in calendar days) between consecutive rate
    /// entries in the in-memory cache for `base`. A gap of N means there
    /// are N − 1 un-fetched interior days between two adjacent data points.
    /// Used by contiguity tests to assert the bounded-window invariant.
    func debugMaxInteriorGapDays(base: String) -> Int {
      caches[base]?.rates.maxInteriorGapDays ?? 0
    }
  }
#endif

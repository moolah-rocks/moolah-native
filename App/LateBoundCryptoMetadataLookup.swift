import Foundation

/// Keyed plug the crypto price service uses to self-resolve a crypto
/// instrument's `CryptoRegistration` (mapping + `pricingStatus`) by id.
typealias CryptoMetadataLookup = @Sendable (String) async throws -> CryptoRegistration?

/// Late-bindable `CryptoMetadataLookup`. On the preview/legacy fallback path
/// the `CryptoPriceService` is constructed (in `makeMarketDataServices`)
/// before the per-profile instrument registry exists (built downstream in
/// `makeCloudKitBackend`), so the registry-backed lookup is rotated in once
/// the registry is available — mirroring how the registry's own sync hooks
/// are attached after construction. Until bound it resolves `nil` (no crypto
/// registration), and `makeCloudKitBackend` always binds it synchronously
/// before any conversion runs. The shared (production) scope does not use
/// this — it injects its registry-backed closure directly, since the shared
/// registry is built alongside the shared `CryptoPriceService`.
///
/// `@unchecked Sendable` per `guides/CONCURRENCY_GUIDE.md` Carve-out 6: a
/// late-bound fallback metadata box whose only mutable state (`resolver`) is
/// fully guarded by an `NSLock`. The lock is never held across an `await` —
/// the bound value is copied out under the lock and the async call made after
/// release. `bind(_:)` runs synchronously during `ProfileSession` /
/// `makeCloudKitBackend` init, before any concurrent access. `@unchecked`
/// waives only the structural `final class` Sendable check.
final class LateBoundCryptoMetadataLookup: @unchecked Sendable {
  private let lock = NSLock()
  private var resolver: CryptoMetadataLookup?

  func bind(_ resolver: @escaping CryptoMetadataLookup) {
    lock.withLock { self.resolver = resolver }
  }

  /// The closure to hand to `CryptoPriceService.metadataLookup`. Reads the
  /// bound resolver under the lock on each call so a registration added to
  /// the registry after binding is still picked up live.
  var lookup: CryptoMetadataLookup {
    { [self] id in
      let resolver = lock.withLock { self.resolver }
      guard let resolver else { return nil }
      return try await resolver(id)
    }
  }
}

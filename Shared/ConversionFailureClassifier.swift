import Foundation

/// Classifies an error thrown by the instrument-conversion path as a
/// *transient* price-availability failure (the rate is temporarily
/// unfetchable — a throttled provider, a network blip, a day not yet
/// warmed) versus a *structural* failure (the conversion can never
/// succeed — an unsupported pair, a permanently unmapped token).
///
/// The Analysis expense/income aggregations degrade per-row on transient
/// failures (skip the row, render the rest, self-heal once prices warm)
/// but preserve the loud rethrow for structural failures. See
/// `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11 and issue #1075.
enum ConversionFailureClassifier {
  static func isTransient(_ error: any Error) -> Bool {
    switch error {
    case is RateLimitGateError:
      return true
    case let walletSync as WalletSyncError:
      switch walletSync.kind {
      case .network, .rateLimited:
        return true
      case .missingApiKey, .invalidApiKey, .providerMalformedResponse:
        return false
      }
    case let cryptoPrice as CryptoPriceError:
      switch cryptoPrice {
      case .noPriceAvailable, .allProvidersFailed:
        return true
      case .noProviderMapping:
        return false
      }
    case is URLError:
      return true
    default:
      return false
    }
  }
}

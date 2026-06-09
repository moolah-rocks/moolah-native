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
    case is RateLimitGateError, is URLError:
      return true
    case let walletSync as WalletSyncError:
      return isTransient(walletSync)
    case let cryptoPrice as CryptoPriceError:
      return isTransient(cryptoPrice)
    case let conversionError as ConversionError:
      return isTransient(conversionError)
    default:
      return false
    }
  }

  private static func isTransient(_ error: WalletSyncError) -> Bool {
    switch error.kind {
    case .network, .rateLimited:
      return true
    case .missingApiKey, .invalidApiKey, .providerMalformedResponse:
      return false
    }
  }

  private static func isTransient(_ error: CryptoPriceError) -> Bool {
    switch error {
    case .noPriceAvailable, .allProvidersFailed:
      return true
    case .noProviderMapping:
      return false
    }
  }

  /// Every `ConversionError` case is structural — an unsupported pair, an
  /// unmapped token, a missing price service — so retrying cannot fix it.
  /// The exhaustive switch makes a future `ConversionError` case a compile
  /// error here rather than a silent `false`.
  private static func isTransient(_ error: ConversionError) -> Bool {
    switch error {
    case .unsupportedInstrumentKind, .unsupportedConversion, .noCryptoPriceService,
      .noProviderMapping:
      return false
    }
  }
}

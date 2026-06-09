import Foundation
import Testing

@testable import Moolah

@Suite("ConversionFailureClassifier")
struct ConversionFailureClassifierTests {

  @Test("rate-limit cooldown is transient")
  func cooldownIsTransient() {
    let error = RateLimitGateError.cooldown(until: Date(timeIntervalSince1970: 1))
    #expect(ConversionFailureClassifier.isTransient(error))
  }

  @Test("WalletSyncError .network is transient")
  func networkIsTransient() {
    let error = WalletSyncError(provider: .binance, kind: .network(underlyingDescription: "x"))
    #expect(ConversionFailureClassifier.isTransient(error))
  }

  @Test("WalletSyncError .rateLimited is transient")
  func rateLimitedIsTransient() {
    let error = WalletSyncError(provider: .binance, kind: .rateLimited(retryAfter: nil))
    #expect(ConversionFailureClassifier.isTransient(error))
  }

  @Test("CryptoPriceError .noPriceAvailable is transient")
  func noPriceAvailableIsTransient() {
    let error = CryptoPriceError.noPriceAvailable(tokenId: "1:native", date: "2026-01-01")
    #expect(ConversionFailureClassifier.isTransient(error))
  }

  @Test("URLError is transient")
  func urlErrorIsTransient() {
    #expect(ConversionFailureClassifier.isTransient(URLError(.timedOut)))
  }

  @Test("structural conversion errors are not transient")
  func structuralNotTransient() {
    #expect(
      !ConversionFailureClassifier.isTransient(
        ConversionError.unsupportedConversion(from: "A", to: "B")))
    #expect(
      !ConversionFailureClassifier.isTransient(
        ConversionError.noProviderMapping(instrumentId: "1:0xabc")))
    #expect(
      !ConversionFailureClassifier.isTransient(
        CryptoPriceError.noProviderMapping(tokenId: "1:0xabc", provider: "Binance")))
    #expect(
      !ConversionFailureClassifier.isTransient(
        WalletSyncError(provider: .binance, kind: .invalidApiKey)))
  }
}

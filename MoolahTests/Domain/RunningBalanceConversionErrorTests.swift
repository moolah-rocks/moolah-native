import Foundation
import Testing

@testable import Moolah

/// `RunningBalanceConversionError.errorDescription` is surfaced verbatim
/// through `Error.userMessage` into the running-balance error banner, so
/// it must be user-readable. It must NOT leak the raw underlying error
/// description (Swift enum names, contract addresses, provider names
/// from the price provider's internal failure surface), but it MUST
/// name the target instrument so the user understands which conversion
/// is unavailable.
@Suite("RunningBalanceConversionError user-facing text")
struct RunningBalanceConversionErrorTests {
  private let realisticUnderlying =
    "noProviderMapping(tokenId: \"1:0xdac17f958d2ee523a2206206994597c13d831ec7\", "
    + "provider: \"Binance\")"

  @Test
  func errorDescriptionDoesNotLeakUnderlyingDetail() throws {
    let error = RunningBalanceConversionError(
      transactionId: UUID(),
      targetInstrumentId: "AUD",
      underlyingDescription: realisticUnderlying)
    let text = try #require(error.errorDescription)
    #expect(!text.contains("noProviderMapping"))
    #expect(!text.contains("Binance"))
    #expect(!text.contains("0xdac17"))
    #expect(!text.contains("tokenId"))
  }

  @Test
  func errorDescriptionNamesTargetInstrument() throws {
    let error = RunningBalanceConversionError(
      transactionId: UUID(),
      targetInstrumentId: "AUD",
      underlyingDescription: realisticUnderlying)
    let text = try #require(error.errorDescription)
    #expect(text.contains("AUD"))
  }

  /// `underlyingDescription` is still useful for log diagnostics —
  /// `TransactionStore+Observation` logs the full text at `.error` so
  /// support can see provider details — so keep it as a stored property
  /// even though we no longer interpolate it into `errorDescription`.
  @Test
  func underlyingDescriptionRemainsAccessibleForLogging() {
    let error = RunningBalanceConversionError(
      transactionId: UUID(),
      targetInstrumentId: "AUD",
      underlyingDescription: realisticUnderlying)
    #expect(error.underlyingDescription == realisticUnderlying)
  }
}

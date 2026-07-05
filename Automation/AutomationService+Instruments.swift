import Foundation

/// The fields needed to register a crypto token as a priced instrument.
/// Bundled into one value so the registration call stays within the
/// parameter-count budget and reads as a single request.
struct CryptoInstrumentSpec: Sendable {
  /// Chain id forming the instrument id prefix. Need not be a synced chain.
  let chainId: Int
  /// Token contract address, lower-cased into the id. Nil/blank → `:native`.
  let contractAddress: String?
  let symbol: String
  let name: String
  let decimals: Int
  let coingeckoId: String?
  let binanceSymbol: String?
}

// Instrument registration for `AutomationService`. Scripts that reconstruct a
// venue's history in real tokens (e.g. a migration that manually re-enters the
// transactions of a wallet/exchange the app can't sync) need each token to
// exist as a priced `Instrument` before a token-denominated leg can resolve —
// `add leg … instrument "<chain>:<contract>"` throws on an unregistered crypto
// id. This verb registers (or upserts) that token plus its price-provider
// mapping, mirroring what the wallet-sync token-discovery path does
// automatically for synced chains.
extension AutomationService {

  /// Registers (or upserts) a crypto token and its price-provider mapping in
  /// the profile's instrument registry, returning the resulting `Instrument`.
  ///
  /// The instrument id is derived as `"\(chainId):\(contractAddress)"`
  /// (lower-cased) or `"\(chainId):native"` when `contractAddress` is
  /// nil/blank. `chainId` need not be a synced chain — a token held only on an
  /// unsynced chain (Starknet, Scroll, …) is still valued from its provider
  /// mapping, independent of wallet-sync support.
  ///
  /// At least one provider identifier (`coingeckoId`, `binanceSymbol`) must
  /// be supplied; without one the token can't be priced and the call throws
  /// rather than register an unpriceable stub.
  @discardableResult
  func registerCryptoInstrument(
    profileIdentifier: String,
    spec: CryptoInstrumentSpec
  ) async throws -> Instrument {
    let session = try resolveSession(for: profileIdentifier)
    guard let registry = session.instrumentRegistry else {
      throw AutomationError.operationFailed(
        "Instrument registry unavailable for profile '\(profileIdentifier)'")
    }

    let trimmedSymbol = spec.symbol.trimmingCharacters(in: .whitespacesAndNewlines)
    let trimmedName = spec.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedSymbol.isEmpty, !trimmedName.isEmpty else {
      throw AutomationError.invalidParameter("Instrument symbol and name must not be empty")
    }
    guard spec.decimals >= 0 else {
      throw AutomationError.invalidParameter("Instrument decimals must be >= 0")
    }

    let instrument = Instrument.crypto(
      chainId: spec.chainId,
      contractAddress: nonEmpty(spec.contractAddress),
      symbol: trimmedSymbol,
      name: trimmedName,
      decimals: spec.decimals)

    let mapping = CryptoProviderMapping(
      instrumentId: instrument.id,
      coingeckoId: nonEmpty(spec.coingeckoId),
      binanceSymbol: nonEmpty(spec.binanceSymbol))
    guard mapping.hasProviderMapping else {
      throw AutomationError.invalidParameter(
        "A crypto instrument needs at least one price source: "
          + "coingecko id or binance symbol")
    }

    do {
      try await registry.registerCrypto(instrument, mapping: mapping)
    } catch {
      throw AutomationError.operationFailed(
        "Failed to register instrument '\(instrument.id)': \(error.localizedDescription)")
    }
    return instrument
  }

  /// Trims whitespace and maps an empty/absent string to nil.
  private func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else { return nil }
    return trimmed
  }
}

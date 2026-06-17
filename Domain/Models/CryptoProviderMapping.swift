// Domain/Models/CryptoProviderMapping.swift
import Foundation

/// Maps a crypto instrument to its price provider identifiers.
/// Separated from Instrument because provider IDs are lookup metadata,
/// not financial instrument identity.
struct CryptoProviderMapping: Codable, Sendable, Hashable, Identifiable {
  let instrumentId: String  // Matches Instrument.id, e.g. "1:native", "10:0xabc..."

  let coingeckoId: String?
  let cryptocompareSymbol: String?
  let binanceSymbol: String?

  var id: String { instrumentId }

  /// Returns `true` when at least one provider identifier is populated —
  /// i.e. this instrument has a price-provider mapping. The callers
  /// (`ExchangeInstrumentResolver`, `CryptoTokenDiscoveryService`) use
  /// this to distinguish a mapped/`.priced` registration from an
  /// `.unpriced` stub.
  var hasProviderMapping: Bool {
    coingeckoId != nil || cryptocompareSymbol != nil || binanceSymbol != nil
  }

  /// Canonical cross-chain asset key: the curated price-provider id, which is
  /// shared by every chain's variant of the same asset (e.g. `"ethereum"` for
  /// ETH on mainnet and every L2). Falls back to the instrument's own id when
  /// no provider id is present, so an unmapped token matches no other asset.
  var assetKey: String {
    coingeckoId ?? cryptocompareSymbol ?? binanceSymbol ?? instrumentId
  }

  /// Merge-only fill: each nil provider id is taken from `other`; a populated
  /// column is never overwritten, and `instrumentId` is always kept. Used by
  /// the startup re-detection pass to upgrade a stored mapping from the
  /// provider caches without downgrading anything (#1140).
  func merging(_ other: CryptoProviderMapping) -> CryptoProviderMapping {
    CryptoProviderMapping(
      instrumentId: instrumentId,
      coingeckoId: coingeckoId ?? other.coingeckoId,
      cryptocompareSymbol: cryptocompareSymbol ?? other.cryptocompareSymbol,
      binanceSymbol: binanceSymbol ?? other.binanceSymbol)
  }

  /// Built-in presets for common tokens.
  static let builtInPresets: [CryptoProviderMapping] =
    CryptoRegistration.builtInPresets.map(\.mapping)
}

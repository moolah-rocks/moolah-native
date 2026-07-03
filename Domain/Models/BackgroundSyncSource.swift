import Foundation

/// A background-sync data source that automatically creates transactions:
/// on-chain wallet sync or an exchange sync. Distinct from user-initiated
/// CSV / bank / web file imports, which also stamp an `ImportOrigin` but are
/// not surfaced as "synced".
///
/// The `parserIdentifier` values are the single source of truth for the
/// tokens stamped onto every synced transaction's `ImportOrigin` — the sync
/// factories in `ProfileSession+CryptoSync` read them from here, so the
/// producer and this consumer cannot drift apart.
enum BackgroundSyncSource: CaseIterable, Hashable, Sendable {
  case wallet
  case coinstash

  /// The `ImportOrigin.parserIdentifier` a transaction from this source
  /// carries. Referenced by the sync factories so there is one definition.
  var parserIdentifier: String {
    switch self {
    case .wallet: return "alchemy-wallet-sync"
    case .coinstash: return "coinstash"
    }
  }

  /// The user-facing source name shown in the sync-origin indicator. `.wallet`
  /// reads as "Wallet" (how the user thinks of a synced on-chain wallet)
  /// rather than the RPC provider brand.
  var displayName: String {
    switch self {
    case .wallet: return "Wallet"
    case .coinstash: return "Coinstash"
    }
  }

  /// Resolves an `ImportOrigin.parserIdentifier` to a background-sync source,
  /// or `nil` when the identifier is not one (manual entry has no origin;
  /// CSV / bank / web imports use their own parser ids).
  init?(parserIdentifier: String) {
    guard
      let match = Self.allCases.first(where: { $0.parserIdentifier == parserIdentifier })
    else { return nil }
    self = match
  }
}

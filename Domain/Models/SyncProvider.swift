// Domain/Models/SyncProvider.swift
import Foundation

/// Identifies which external data provider produced a sync failure, so
/// `WalletSyncError` can attribute the error to its source. String-backed
/// so it round-trips as a stable token inside the persisted
/// `WalletSyncState.lastError` JSON. Per-device only — not a synced
/// record, so adding a case does not touch `DataFormatVersion`.
enum SyncProvider: String {
  case alchemy
  case blockExplorer
  case coinstash
  case coinGecko
  case binance
  case peggedStablecoin
  case defiLlama

  /// Returns the user-facing brand name for each case, shown in the
  /// synced-account error caption. `.blockExplorer` resolves to the concrete
  /// brand "Blockscout" for consistency with captions that already surface the
  /// concrete brand "Alchemy".
  var displayName: String {
    switch self {
    case .alchemy: return "Alchemy"
    case .blockExplorer: return "Blockscout"
    case .coinstash: return "Coinstash"
    case .coinGecko: return "CoinGecko"
    case .binance: return "Binance"
    case .peggedStablecoin: return "Pegged Stablecoin"
    case .defiLlama: return "DefiLlama"
    }
  }
}

// MARK: - Protocol conformances

extension SyncProvider: Codable {}
extension SyncProvider: Sendable {}
extension SyncProvider: Hashable {}
extension SyncProvider: CaseIterable {}

import Foundation

/// Single injection point for all repository and auth instances.
/// Pass a different BackendProvider to @Environment to swap the entire backend.
protocol BackendProvider: Sendable {
  var auth: any AuthProvider { get }
  var accounts: any AccountRepository { get }
  var transactions: any TransactionRepository { get }
  var categories: any CategoryRepository { get }
  var transferSuggestions: any TransferSuggestionRepository { get }
  var earmarks: any EarmarkRepository { get }
  var analysis: any AnalysisRepository { get }
  var investments: any InvestmentRepository { get }
  var conversionService: any InstrumentConversionService { get }
  var csvImportProfiles: any CSVImportProfileRepository { get }
  var importRules: any ImportRuleRepository { get }
  /// Per-device sync checkpoints for crypto wallet accounts. Local-only
  /// (not synced via CKSyncEngine — see `WalletSyncStateRepository`
  /// doc-comment).
  var walletSyncState: any WalletSyncStateRepository { get }

  /// Narrow change-notification seam over the backend's shared
  /// instrument registry, or `nil` for backends that have no shared
  /// registry (e.g. lightweight test doubles). Per-profile stores
  /// thread this into their observation so a shared-registry metadata
  /// edit live-refreshes an open list across the DB boundary, without
  /// the factory having to downcast to a concrete backend type. Named
  /// for the seam (not `instrumentRegistry`) because it deliberately
  /// exposes only `InstrumentChangeObserving` — not the full
  /// read/write registry surface.
  var instrumentChangeObserver: (any InstrumentChangeObserving)? { get }
}

extension BackendProvider {
  /// Default for backends without a shared instrument registry. Only a
  /// backend that actually owns one (production `CloudKitBackend`)
  /// overrides this — keeps the blast radius of the seam to a single
  /// conformer.
  var instrumentChangeObserver: (any InstrumentChangeObserving)? { nil }
}

import Foundation

/// Single injection point for all repository and auth instances.
/// Pass a different BackendProvider to @Environment to swap the entire backend.
protocol BackendProvider: Sendable {
  var auth: any AuthProvider { get }
  var accounts: any AccountRepository { get }
  var accountGroups: any AccountGroupRepository { get }
  /// Per-`InsightKind` dismissal tallies driving `InsightRanker`'s fatigue
  /// penalty. Synced via CKSyncEngine so a dismissal propagates across devices.
  var insightDismissals: any InsightDismissalRepository { get }
  var transactions: any TransactionRepository { get }
  var categories: any CategoryRepository { get }
  var transferSuggestions: any TransferSuggestionRepository { get }
  var earmarks: any EarmarkRepository { get }
  var analysis: any AnalysisRepository { get }
  /// SQL-backed assembler of the pre-aggregated insight summaries + bounded
  /// recent-candidate window the deterministic `InsightEngine` consumes.
  /// Built from the same per-profile database as `analysis`.
  var insightDataSource: any InsightDataSource { get }
  var investments: any InvestmentRepository { get }
  var conversionService: any InstrumentConversionService { get }
  var csvImportProfiles: any CSVImportProfileRepository { get }
  var importRules: any ImportRuleRepository { get }
  /// Per-device sync checkpoints for crypto wallet accounts. Local-only
  /// (not synced via CKSyncEngine — see `WalletSyncStateRepository`
  /// doc-comment).
  var walletSyncState: any WalletSyncStateRepository { get }
  /// Per-device sidebar expand / collapse state for `AccountGroup` rows.
  /// Local-only (not synced via CKSyncEngine — expand state is per-device
  /// UX preference, not data). See `GroupUIStateRepository` doc-comment.
  var groupUIState: any GroupUIStateRepository { get }

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

  /// The full instrument registry, when the backend has one. Mirrors the
  /// narrow `instrumentChangeObserver` seam but exposes read access to crypto
  /// registrations (for the holdings cross-chain asset-key rollup). `nil` for
  /// backends without a registry (e.g. preview/empty backends).
  var instrumentRegistry: (any InstrumentRegistryRepository)? { get }
}

extension BackendProvider {
  /// Default for backends without a shared instrument registry. Only a
  /// backend that actually owns one (production `CloudKitBackend`)
  /// overrides this — keeps the blast radius of the seam to a single
  /// conformer.
  var instrumentChangeObserver: (any InstrumentChangeObserving)? { nil }

  /// Default for backends without a shared instrument registry. Only a
  /// backend that actually owns one (production `CloudKitBackend`)
  /// overrides this.
  var instrumentRegistry: (any InstrumentRegistryRepository)? { nil }
}

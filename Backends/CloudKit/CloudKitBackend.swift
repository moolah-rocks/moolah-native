import Foundation
import GRDB

final class CloudKitBackend: BackendProvider, @unchecked Sendable {
  let auth: any AuthProvider
  let accounts: any AccountRepository
  let accountGroups: any AccountGroupRepository
  let insightDismissals: any InsightDismissalRepository
  let transactions: any TransactionRepository
  let categories: any CategoryRepository
  let transferSuggestions: any TransferSuggestionRepository
  let earmarks: any EarmarkRepository
  let analysis: any AnalysisRepository
  let insightDataSource: any InsightDataSource
  let investments: any InvestmentRepository
  let conversionService: any InstrumentConversionService
  let csvImportProfiles: any CSVImportProfileRepository
  let importRules: any ImportRuleRepository
  let instrumentRegistry: any InstrumentRegistryRepository
  let walletSyncState: any WalletSyncStateRepository
  let groupUIState: any GroupUIStateRepository

  /// `BackendProvider` change-notification seam: the shared
  /// `GRDBInstrumentRegistryRepository` exposed as the narrow
  /// `InstrumentChangeObserving` surface. `InstrumentRegistryRepository`
  /// already refines `InstrumentChangeObserving`, so this is the same
  /// instance up-cast — no extra wiring.
  var instrumentChangeObserver: (any InstrumentChangeObserving)? {
    instrumentRegistry
  }
  /// Concrete GRDB-backed repositories. Exposed alongside the
  /// protocol-typed properties so `ProfileSession` can register the
  /// concrete instances with `SyncCoordinator` (which needs the concrete
  /// class type to reach the synchronous sync entry points). The
  /// protocol-typed properties point at the same instances.
  let grdbCSVImportProfiles: GRDBCSVImportProfileRepository
  let grdbImportRules: GRDBImportRuleRepository
  let grdbInstruments: GRDBInstrumentRegistryRepository
  let grdbAccounts: GRDBAccountRepository
  let grdbAccountGroups: GRDBAccountGroupRepository
  let grdbInsightDismissals: GRDBInsightDismissalRepository
  let grdbCategories: GRDBCategoryRepository
  let grdbTransferSuggestions: GRDBTransferSuggestionRepository
  let grdbEarmarks: GRDBEarmarkRepository
  let grdbEarmarkBudgetItems: GRDBEarmarkBudgetItemRepository
  let grdbInvestments: GRDBInvestmentRepository
  let grdbTransactions: GRDBTransactionRepository
  let grdbTransactionLegs: GRDBTransactionLegRepository

  /// Bundle of the change/delete hook closures the GRDB repos call on
  /// each successful local mutation. Bundling keeps
  /// `CloudKitBackend.init`'s parameter list small while still letting
  /// callers inject distinct closures per repo if they need to (no
  /// current caller does — `makeCloudKitBackend` shares one pair across
  /// every repo).
  struct CloudKitBackendHooks {
    let onCSVImportProfileChanged: @Sendable (String, UUID) -> Void
    let onCSVImportProfileDeleted: @Sendable (String, UUID) -> Void
    let onImportRuleChanged: @Sendable (String, UUID) -> Void
    let onImportRuleDeleted: @Sendable (String, UUID) -> Void
    let onAccountChanged: @Sendable (String, UUID) -> Void
    let onAccountDeleted: @Sendable (String, UUID) -> Void
    let onAccountGroupChanged: @Sendable (String, UUID) -> Void
    let onAccountGroupDeleted: @Sendable (String, UUID) -> Void
    let onInsightDismissalChanged: @Sendable (String, UUID) -> Void
    let onInsightDismissalDeleted: @Sendable (String, UUID) -> Void
    let onCategoryChanged: @Sendable (String, UUID) -> Void
    let onCategoryDeleted: @Sendable (String, UUID) -> Void
    let onTransferSuggestionChanged: @Sendable (String, UUID) -> Void
    let onTransferSuggestionDeleted: @Sendable (String, UUID) -> Void
    let onEarmarkChanged: @Sendable (String, UUID) -> Void
    let onEarmarkDeleted: @Sendable (String, UUID) -> Void
    let onEarmarkBudgetItemChanged: @Sendable (String, UUID) -> Void
    let onEarmarkBudgetItemDeleted: @Sendable (String, UUID) -> Void
    let onInvestmentChanged: @Sendable (String, UUID) -> Void
    let onInvestmentDeleted: @Sendable (String, UUID) -> Void
    let onTransactionChanged: @Sendable (String, UUID) -> Void
    let onTransactionDeleted: @Sendable (String, UUID) -> Void
    let onTransactionLegChanged: @Sendable (String, UUID) -> Void
    let onTransactionLegDeleted: @Sendable (String, UUID) -> Void

    static let noop = CloudKitBackendHooks(
      onCSVImportProfileChanged: { _, _ in },
      onCSVImportProfileDeleted: { _, _ in },
      onImportRuleChanged: { _, _ in },
      onImportRuleDeleted: { _, _ in },
      onAccountChanged: { _, _ in },
      onAccountDeleted: { _, _ in },
      onAccountGroupChanged: { _, _ in },
      onAccountGroupDeleted: { _, _ in },
      onInsightDismissalChanged: { _, _ in },
      onInsightDismissalDeleted: { _, _ in },
      onCategoryChanged: { _, _ in },
      onCategoryDeleted: { _, _ in },
      onTransferSuggestionChanged: { _, _ in },
      onTransferSuggestionDeleted: { _, _ in },
      onEarmarkChanged: { _, _ in },
      onEarmarkDeleted: { _, _ in },
      onEarmarkBudgetItemChanged: { _, _ in },
      onEarmarkBudgetItemDeleted: { _, _ in },
      onInvestmentChanged: { _, _ in },
      onInvestmentDeleted: { _, _ in },
      onTransactionChanged: { _, _ in },
      onTransactionDeleted: { _, _ in },
      onTransactionLegChanged: { _, _ in },
      onTransactionLegDeleted: { _, _ in })
  }

  init(
    database: any DatabaseWriter,
    instrument: Instrument,
    profileLabel: String,
    conversionService: any InstrumentConversionService,
    instrumentRegistry: GRDBInstrumentRegistryRepository,
    hooks: CloudKitBackendHooks = .noop
  ) {
    self.auth = CloudKitAuthProvider(profileLabel: profileLabel)
    let repos = Self.makeRepositories(
      database: database,
      instrument: instrument,
      conversionService: conversionService,
      instrumentSeams: InstrumentSeams(
        resolver: instrumentRegistry, registrar: instrumentRegistry),
      hooks: hooks)

    self.grdbAccounts = repos.accounts
    self.grdbAccountGroups = repos.accountGroups
    self.grdbInsightDismissals = repos.insightDismissals
    self.grdbTransactions = repos.transactions
    self.grdbCategories = repos.categories
    self.grdbTransferSuggestions = repos.transferSuggestions
    self.grdbEarmarks = repos.earmarks
    self.grdbEarmarkBudgetItems = repos.earmarkBudgetItems
    self.grdbInvestments = repos.investments
    self.grdbTransactionLegs = repos.transactionLegs
    self.grdbCSVImportProfiles = repos.csvImportProfiles
    self.grdbImportRules = repos.importRules
    self.grdbInstruments = instrumentRegistry

    self.accounts = repos.accounts
    self.accountGroups = repos.accountGroups
    self.insightDismissals = repos.insightDismissals
    self.transactions = repos.transactions
    self.categories = repos.categories
    self.transferSuggestions = repos.transferSuggestions
    self.earmarks = repos.earmarks
    self.analysis = repos.analysis
    self.insightDataSource = repos.insightDataSource
    self.investments = repos.investments
    self.csvImportProfiles = repos.csvImportProfiles
    self.importRules = repos.importRules
    self.instrumentRegistry = instrumentRegistry
    self.conversionService = conversionService
    self.walletSyncState = GRDBWalletSyncStateRepository(database: database)
    self.groupUIState = GRDBGroupUIStateRepository(database: database)
  }

  /// The read-side instrument resolver and the write-side registrar,
  /// bundled to keep the repository-construction helpers' parameter
  /// lists small. In production both are the same shared
  /// `GRDBInstrumentRegistryRepository`; the type keeps them distinct
  /// so the seams remain independently swappable. The repository-factory
  /// helpers that consume this live in `CloudKitBackend+Repositories`.
  struct InstrumentSeams {
    let resolver: any InstrumentMapResolving
    let registrar: any InstrumentRegistering
  }
}

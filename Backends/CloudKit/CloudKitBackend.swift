import Foundation
import GRDB

final class CloudKitBackend: BackendProvider, @unchecked Sendable {
  let auth: any AuthProvider
  let accounts: any AccountRepository
  let transactions: any TransactionRepository
  let categories: any CategoryRepository
  let transferSuggestions: any TransferSuggestionRepository
  let earmarks: any EarmarkRepository
  let analysis: any AnalysisRepository
  let investments: any InvestmentRepository
  let conversionService: any InstrumentConversionService
  let csvImportProfiles: any CSVImportProfileRepository
  let importRules: any ImportRuleRepository
  let instrumentRegistry: any InstrumentRegistryRepository
  let walletSyncState: any WalletSyncStateRepository

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
    self.transactions = repos.transactions
    self.categories = repos.categories
    self.transferSuggestions = repos.transferSuggestions
    self.earmarks = repos.earmarks
    self.analysis = repos.analysis
    self.investments = repos.investments
    self.csvImportProfiles = repos.csvImportProfiles
    self.importRules = repos.importRules
    self.instrumentRegistry = instrumentRegistry
    self.conversionService = conversionService
    self.walletSyncState = GRDBWalletSyncStateRepository(database: database)
  }

  /// Bundle of GRDB repositories produced by `makeRepositories`. Keeps
  /// the init body compact by handing back one value rather than ten.
  private struct GRDBRepositoryBundle {
    let accounts: GRDBAccountRepository
    let transactions: GRDBTransactionRepository
    let categories: GRDBCategoryRepository
    let transferSuggestions: GRDBTransferSuggestionRepository
    let earmarks: GRDBEarmarkRepository
    let earmarkBudgetItems: GRDBEarmarkBudgetItemRepository
    let investments: GRDBInvestmentRepository
    let transactionLegs: GRDBTransactionLegRepository
    let analysis: GRDBAnalysisRepository
    let csvImportProfiles: GRDBCSVImportProfileRepository
    let importRules: GRDBImportRuleRepository
  }

  /// Constructs every GRDB-backed repository against the same writer
  /// and hook fan-out, bundled so `init` only has to plumb the result
  /// onto its stored properties.
  private static func makeRepositories(
    database: any DatabaseWriter,
    instrument: Instrument,
    conversionService: any InstrumentConversionService,
    instrumentSeams: InstrumentSeams,
    hooks: CloudKitBackendHooks
  ) -> GRDBRepositoryBundle {
    // The instrument-resolving read repos (accounts, transactions,
    // earmarks, investments, analysis) all take the instrument seams;
    // the remaining record-type repos don't, so the two groups are
    // built by separate helpers.
    let resolving = makeResolvingRepositories(
      database: database,
      instrument: instrument,
      conversionService: conversionService,
      instrumentSeams: instrumentSeams,
      hooks: hooks)
    return GRDBRepositoryBundle(
      accounts: resolving.accounts,
      transactions: resolving.transactions,
      categories: GRDBCategoryRepository(
        database: database,
        onRecordChanged: hooks.onCategoryChanged,
        onRecordDeleted: hooks.onCategoryDeleted),
      transferSuggestions: GRDBTransferSuggestionRepository(
        database: database,
        onRecordChanged: hooks.onTransferSuggestionChanged,
        onRecordDeleted: hooks.onTransferSuggestionDeleted),
      earmarks: resolving.earmarks,
      earmarkBudgetItems: GRDBEarmarkBudgetItemRepository(
        database: database,
        onRecordChanged: hooks.onEarmarkBudgetItemChanged,
        onRecordDeleted: hooks.onEarmarkBudgetItemDeleted),
      investments: resolving.investments,
      transactionLegs: GRDBTransactionLegRepository(
        database: database,
        onRecordChanged: hooks.onTransactionLegChanged,
        onRecordDeleted: hooks.onTransactionLegDeleted),
      analysis: resolving.analysis,
      csvImportProfiles: GRDBCSVImportProfileRepository(
        database: database,
        onRecordChanged: hooks.onCSVImportProfileChanged,
        onRecordDeleted: hooks.onCSVImportProfileDeleted),
      importRules: GRDBImportRuleRepository(
        database: database,
        onRecordChanged: hooks.onImportRuleChanged,
        onRecordDeleted: hooks.onImportRuleDeleted))
  }

  /// The five repositories that resolve instruments via the injected
  /// `InstrumentMapResolving`. Grouped together semantically:
  /// resolver-dependent repositories belong here, so a future repository
  /// that needs the resolver is added here, not into the main
  /// `makeRepositories` body.
  private struct ResolvingRepositories {
    let accounts: GRDBAccountRepository
    let transactions: GRDBTransactionRepository
    let earmarks: GRDBEarmarkRepository
    let investments: GRDBInvestmentRepository
    let analysis: GRDBAnalysisRepository
  }

  /// The read-side instrument resolver and the write-side registrar,
  /// bundled to keep the repository-construction helpers' parameter
  /// lists small. In production both are the same shared
  /// `GRDBInstrumentRegistryRepository`; the type keeps them distinct
  /// so the seams remain independently swappable.
  struct InstrumentSeams {
    let resolver: any InstrumentMapResolving
    let registrar: any InstrumentRegistering
  }

  private static func makeResolvingRepositories(
    database: any DatabaseWriter,
    instrument: Instrument,
    conversionService: any InstrumentConversionService,
    instrumentSeams: InstrumentSeams,
    hooks: CloudKitBackendHooks
  ) -> ResolvingRepositories {
    let resolver = instrumentSeams.resolver
    return ResolvingRepositories(
      accounts: GRDBAccountRepository(
        database: database,
        instrumentResolver: resolver,
        instrumentRegistrar: instrumentSeams.registrar,
        onRecordChanged: hooks.onAccountChanged,
        onRecordDeleted: hooks.onAccountDeleted),
      transactions: GRDBTransactionRepository(
        database: database,
        defaultInstrument: instrument,
        conversionService: conversionService,
        instrumentResolver: resolver,
        instrumentRegistrar: instrumentSeams.registrar,
        onRecordChanged: hooks.onTransactionChanged,
        onRecordDeleted: hooks.onTransactionDeleted),
      earmarks: GRDBEarmarkRepository(
        database: database,
        defaultInstrument: instrument,
        instrumentResolver: resolver,
        onRecordChanged: hooks.onEarmarkChanged,
        onRecordDeleted: hooks.onEarmarkDeleted),
      investments: GRDBInvestmentRepository(
        database: database,
        defaultInstrument: instrument,
        instrumentResolver: resolver,
        onRecordChanged: hooks.onInvestmentChanged,
        onRecordDeleted: hooks.onInvestmentDeleted),
      analysis: GRDBAnalysisRepository(
        database: database,
        instrument: instrument,
        conversionService: conversionService,
        instrumentResolver: resolver))
  }
}

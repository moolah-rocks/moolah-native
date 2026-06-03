import Foundation
import GRDB

extension CloudKitBackend {
  /// Bundle of GRDB repositories produced by `makeRepositories`. Keeps
  /// the init body compact by handing back one value rather than ten.
  struct GRDBRepositoryBundle {
    let accounts: GRDBAccountRepository
    let accountGroups: GRDBAccountGroupRepository
    let insightDismissals: GRDBInsightDismissalRepository
    let transactions: GRDBTransactionRepository
    let categories: GRDBCategoryRepository
    let transferSuggestions: GRDBTransferSuggestionRepository
    let earmarks: GRDBEarmarkRepository
    let earmarkBudgetItems: GRDBEarmarkBudgetItemRepository
    let investments: GRDBInvestmentRepository
    let transactionLegs: GRDBTransactionLegRepository
    let analysis: GRDBAnalysisRepository
    let insightDataSource: GRDBInsightDataSource
    let csvImportProfiles: GRDBCSVImportProfileRepository
    let importRules: GRDBImportRuleRepository
  }

  /// Constructs every GRDB-backed repository against the same writer
  /// and hook fan-out, bundled so `init` only has to plumb the result
  /// onto its stored properties.
  static func makeRepositories(
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
      accountGroups: GRDBAccountGroupRepository(
        database: database,
        onRecordChanged: hooks.onAccountGroupChanged,
        onRecordDeleted: hooks.onAccountGroupDeleted),
      insightDismissals: GRDBInsightDismissalRepository(
        database: database,
        onRecordChanged: hooks.onInsightDismissalChanged,
        onRecordDeleted: hooks.onInsightDismissalDeleted),
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
      insightDataSource: resolving.insightDataSource,
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
    let insightDataSource: GRDBInsightDataSource
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
        instrumentResolver: resolver),
      insightDataSource: GRDBInsightDataSource(
        database: database,
        instrument: instrument,
        conversionService: conversionService,
        instrumentResolver: resolver))
  }
}

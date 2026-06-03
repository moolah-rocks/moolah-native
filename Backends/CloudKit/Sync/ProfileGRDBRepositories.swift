import Foundation
import GRDB

/// Bundle of the GRDB-backed repositories for the per-profile data
/// handler.
///
/// The dispatch tables in `ProfileDataSyncHandler+ApplyRemoteChanges` /
/// `+SystemFields` consult this bundle for record types that have moved
/// to GRDB and fall through to the SwiftData paths for everything else.
/// Every field is non-optional because in-memory tests, previews, and
/// production all build the GRDB repos eagerly during backend
/// construction.
///
/// **Sendable.** Plain `Sendable` synthesis. Every stored property is
/// `let` and itself `Sendable` — the GRDB repositories are
/// `final class … : @unchecked Sendable`, which satisfies the
/// `Sendable` protocol requirement. The struct has no escape hatches,
/// so the compiler derives `Sendable` automatically and no
/// `@unchecked` waiver is needed.
struct ProfileGRDBRepositories: Sendable {
  let csvImportProfiles: GRDBCSVImportProfileRepository
  let importRules: GRDBImportRuleRepository
  let transferSuggestions: GRDBTransferSuggestionRepository
  let instruments: GRDBInstrumentRegistryRepository
  let categories: GRDBCategoryRepository
  let accounts: GRDBAccountRepository
  let accountGroups: GRDBAccountGroupRepository
  let insightDismissals: GRDBInsightDismissalRepository
  let earmarks: GRDBEarmarkRepository
  let earmarkBudgetItems: GRDBEarmarkBudgetItemRepository
  let investmentValues: GRDBInvestmentRepository
  let transactions: GRDBTransactionRepository
  let transactionLegs: GRDBTransactionLegRepository
  /// Shared writer used by `ProfileDataSyncHandler.applyRemoteChanges` to
  /// open one outer `database.write { ... }` for the whole fetched-changes
  /// batch — saves + deletions across every per-record-type repo land in a
  /// single commit, so `databaseDidCommit` (and the UI `ValueObservation`
  /// re-fetches it drives) fires once. Every repository in this bundle
  /// must already be backed by this same writer; the apply path relies on
  /// that invariant to avoid nested or cross-queue writes. Issue #872.
  let database: any GRDB.DatabaseWriter
}

extension ProfileGRDBRepositories {
  /// Builds a bundle suitable for the sync apply path: every per-type
  /// repository targets `database`, hooks are no-ops, and the read-side
  /// `defaultInstrument` / `conversionService` parameters carry inert
  /// placeholders. The apply path writes Row objects via
  /// `applyRemoteChangesSync` and never invokes either placeholder; the
  /// session-side bundle owned by `CloudKitBackend` continues to carry
  /// real values for user-mutation paths.
  ///
  /// `sharedRegistry` (production CloudKit sync always passes
  /// `SyncCoordinator.sharedInstrumentRegistry`; tests / previews
  /// pass an in-memory shared registry) is injected as the
  /// `instrumentResolver` / `instrumentRegistrar` for every repo that
  /// takes one. The apply path never invokes either seam today —
  /// `applyRemoteChangesSync` writes raw Rows and never calls
  /// `instrumentMap()`, and the apply path never calls
  /// `create` / `createMany` / `update`, so `registerResolvable` is
  /// never reached — but pointing the seams at the shared profile-index
  /// registry guarantees that any future apply-time resolution can
  /// never read or write a per-profile `instrument` table, which does
  /// not exist. There is no per-profile fallback: no production or test
  /// path may read a per-profile `instrument` table.
  ///
  /// The bundle's `instruments` member stays a per-profile
  /// `GRDBInstrumentRegistryRepository(database:)` deliberately: its
  /// only sync caller is `ProfileDataSyncHandler` system-fields
  /// clearing on zone purge / sign-out / account-switch. Pointing it
  /// at the shared, iCloud-account-scoped registry would let one
  /// profile's zone purge mutate every profile's instruments.
  static func makeForApply(
    database: any GRDB.DatabaseWriter,
    sharedRegistry: GRDBInstrumentRegistryRepository
  ) -> ProfileGRDBRepositories {
    // USD is a stable, locale-independent fiat that satisfies
    // `Instrument.fiat(code:)`'s `isoCurrencies` lookup. The choice is
    // arbitrary — only the type matters for the apply path.
    let placeholderInstrument = Instrument.fiat(code: "USD")
    let resolver: any InstrumentMapResolving = sharedRegistry
    let registrar: any InstrumentRegistering = sharedRegistry
    return ProfileGRDBRepositories(
      csvImportProfiles: GRDBCSVImportProfileRepository(database: database),
      importRules: GRDBImportRuleRepository(database: database),
      transferSuggestions: GRDBTransferSuggestionRepository(database: database),
      instruments: GRDBInstrumentRegistryRepository(database: database),
      categories: GRDBCategoryRepository(database: database),
      accounts: GRDBAccountRepository(
        database: database,
        instrumentResolver: resolver,
        instrumentRegistrar: registrar),
      accountGroups: GRDBAccountGroupRepository(database: database),
      insightDismissals: GRDBInsightDismissalRepository(database: database),
      earmarks: GRDBEarmarkRepository(
        database: database,
        defaultInstrument: placeholderInstrument,
        instrumentResolver: resolver),
      earmarkBudgetItems: GRDBEarmarkBudgetItemRepository(database: database),
      investmentValues: GRDBInvestmentRepository(
        database: database,
        defaultInstrument: placeholderInstrument,
        instrumentResolver: resolver),
      transactions: GRDBTransactionRepository(
        database: database,
        defaultInstrument: placeholderInstrument,
        conversionService: ApplyPathConversionService(),
        instrumentResolver: resolver,
        instrumentRegistrar: registrar),
      transactionLegs: GRDBTransactionLegRepository(database: database),
      database: database)
  }
}

/// Placeholder `InstrumentConversionService` for the apply-path bundle.
/// Reachable only from `ProfileGRDBRepositories.makeForApply`;
/// every method throws `ConversionError.unsupportedConversion` because
/// the apply path never reads through the conversion service. If a
/// future code change starts invoking it from the apply path, the
/// error surfaces as a saveFailed result and the offending call site
/// is identifiable from the logs — preferable to silent zero-conversion.
private struct ApplyPathConversionService: InstrumentConversionService {
  func convert(
    _ quantity: Decimal,
    from: Instrument,
    to: Instrument,
    on date: Date
  ) async throws -> Decimal {
    throw ConversionError.unsupportedConversion(from: from.id, to: to.id)
  }

  func convertAmount(
    _ amount: InstrumentAmount,
    to instrument: Instrument,
    on date: Date
  ) async throws -> InstrumentAmount {
    throw ConversionError.unsupportedConversion(
      from: amount.instrument.id, to: instrument.id)
  }

  func convertResult(
    _ amount: InstrumentAmount,
    to instrument: Instrument,
    on date: Date
  ) async throws -> ConversionResult {
    throw ConversionError.unsupportedConversion(
      from: amount.instrument.id, to: instrument.id)
  }

  func invalidateCache(for instrument: Instrument) async {}

  // No-op observation stubs — the apply-path conversion service is
  // never observed (the apply path doesn't drive a UI store), so a
  // single tick on subscription and an empty error stream keep the
  // protocol satisfied without standing up a real GRDB observation.
  func observeRates() -> AsyncStream<Void> {
    AsyncStream { continuation in
      continuation.yield(())
      continuation.finish()
    }
  }

  func observeErrors() -> AsyncStream<any Error> {
    AsyncStream { $0.finish() }
  }
}

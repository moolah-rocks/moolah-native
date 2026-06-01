import Foundation
import GRDB

@testable import Moolah

// A BackendProvider that wires up GRDB-backed repositories on a single
// in-memory queue. Used by the `AnalysisRepository` contract tests.
//
// Visibility is internal (was fileprivate) so sibling test files across the
// split AnalysisRepository* test suites can use this helper — `strict_fileprivate`
// disallows fileprivate in this codebase.
struct CloudKitAnalysisTestBackend: BackendProvider, @unchecked Sendable {
  let auth: any AuthProvider
  let accounts: any AccountRepository
  let accountGroups: any AccountGroupRepository
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
  let walletSyncState: any WalletSyncStateRepository
  let groupUIState: any GroupUIStateRepository

  /// The GRDB queue backing every repository — exposed so tests can seed
  /// rows alongside the standard repository APIs.
  let database: DatabaseQueue

  /// The shared profile-index instrument registry every repository
  /// resolves and registers through. Pointed at its own in-memory
  /// profile-index DB; there is no per-profile `instrument` table.
  /// Exposed so
  /// `fetchAggregationForTesting` resolves the exact instrument map the
  /// repositories built during seeding.
  let instrumentRegistry: GRDBInstrumentRegistryRepository

  /// Creates a backend wired to an in-memory GRDB queue.
  ///
  /// - Parameter customConversion: An optional conversion service override. When
  ///   `nil`, a default `FiatConversionService` backed by a throwaway in-memory
  ///   rate cache is created.
  ///
  /// Throws when the in-memory `DatabaseQueue` fails to construct.
  init(conversionService customConversion: (any InstrumentConversionService)? = nil) throws {
    let database = try ProfileDatabase.openInMemory()
    self.database = database
    let currency = Instrument.defaultTestInstrument
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    self.instrumentRegistry = registry
    let conversion: any InstrumentConversionService
    if let customConversion {
      conversion = customConversion
    } else {
      let rateClient = FixedRateClient()
      // The rate cache lives on the registry's profile-index DB;
      // there are no per-profile rate-cache tables. Pin to UTC so the
      // cap matches fixture date keys built with UTC formatters
      // regardless of the host machine's local zone.
      let utc = TimeZone(identifier: "UTC") ?? .current
      let exchangeRates = ExchangeRateService(
        client: rateClient, database: registry.database, timeZone: utc)
      conversion = FiatConversionService(exchangeRates: exchangeRates)
    }
    let backend = CloudKitBackend(
      database: database,
      instrument: currency,
      profileLabel: "Test",
      conversionService: conversion,
      instrumentRegistry: registry
    )
    self.auth = backend.auth
    self.accounts = backend.accounts
    self.accountGroups = backend.accountGroups
    self.transactions = backend.transactions
    self.categories = backend.categories
    self.transferSuggestions = backend.transferSuggestions
    self.earmarks = backend.earmarks
    self.analysis = backend.analysis
    self.insightDataSource = backend.insightDataSource
    self.investments = backend.investments
    self.conversionService = backend.conversionService
    self.csvImportProfiles = backend.csvImportProfiles
    self.importRules = backend.importRules
    self.walletSyncState = backend.walletSyncState
    self.groupUIState = backend.groupUIState
  }
}

extension CloudKitAnalysisTestBackend {
  /// Test-only entry point that exposes `fetchDailyBalancesAggregation`
  /// for aggregation-layer integration tests. Production callers go
  /// through `analysis.fetchDailyBalances(...)`; this shim lets tests
  /// pin the aggregation contract without re-running the full
  /// per-day walk. Reads from the backend's already-public
  /// `DatabaseQueue` — no peek into `GRDBAnalysisRepository`'s
  /// private storage.
  func fetchAggregationForTesting(
    after: Date?, forecastUntil: Date?
  ) async throws -> GRDBAnalysisRepository.DailyBalancesAggregation {
    // Resolve the instrument map from the shared profile-index registry
    // the repositories registered into during seeding — the same
    // resolver the production aggregation path consults, never the
    // per-profile `instrument` table.
    let instruments = try await instrumentRegistry.instrumentMap()
    return try await GRDBAnalysisRepository.fetchDailyBalancesAggregation(
      database: self.database,
      instruments: instruments,
      after: after,
      forecastUntil: forecastUntil)
  }
}

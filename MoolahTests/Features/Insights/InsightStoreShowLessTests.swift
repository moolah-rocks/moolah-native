import Foundation
import Testing

@testable import Moolah

/// Tests for the "Show less" dismissal contract on `InsightStore`: dropping a
/// visible row without backfilling the next-ranked insight, and rolling the
/// optimistic mutation back (row + per-kind fatigue bump) when the persist
/// fails.
@MainActor
@Suite("InsightStore Show less")
struct InsightStoreShowLessTests {
  private let aud = Instrument.defaultTestInstrument

  // MARK: - Harness

  private func makeProfile() -> Profile {
    Profile(label: "Test", currencyCode: "AUD", financialYearStartMonth: 7)
  }

  private func makeSources(_ backend: any BackendProvider) -> InsightStoreSources {
    InsightStoreSources(
      analysis: AnalysisStore(
        repository: backend.analysis, conversionService: backend.conversionService),
      earmark: EarmarkStore(
        repository: backend.earmarks, conversionService: backend.conversionService,
        targetInstrument: aud, instrumentChanges: nil),
      reporting: ReportingStore(
        transactionRepository: backend.transactions, analysisRepository: backend.analysis,
        conversionService: backend.conversionService, profileCurrency: aud),
      account: AccountStore(
        repository: backend.accounts, conversionService: backend.conversionService,
        targetInstrument: aud, instrumentChanges: nil),
      accountGroup: AccountGroupStore(repository: backend.accountGroups),
      category: CategoryStore(repository: backend.categories))
  }

  private func makeStore(
    _ backend: any BackendProvider, fixtures: [ScoredInsight]
  ) -> InsightStore {
    InsightStore(
      sources: makeSources(backend), backend: backend, profile: makeProfile(),
      instrumentChanges: nil, fixtureInsights: InsightFixtures(insights: fixtures))
  }

  private func makeScoredInsight(id: String, score: Double) -> ScoredInsight {
    ScoredInsight(
      insight: Insight(
        id: id, kind: .netWorthMilestone, title: id,
        date: Date(timeIntervalSince1970: 1_700_000_000),
        framing: .neutral, actionability: .informational, surprise: 0),
      score: score)
  }

  // MARK: - Tests

  @Test("Show less removes the row without backfilling the next-ranked insight")
  func showLessRemovesRowWithoutBackfill() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let fixtures = [
      makeScoredInsight(id: "a", score: 4),
      makeScoredInsight(id: "b", score: 3),
      makeScoredInsight(id: "c", score: 2),
      makeScoredInsight(id: "d", score: 1),
    ]
    let store = makeStore(backend, fixtures: fixtures)
    store.maxVisible = 3
    await store.refresh()
    #expect(store.items.map(\.id) == ["a", "b", "c"])

    let target = try #require(store.items.first { $0.id == "b" })
    await store.dismiss(target.scored)

    // No backfill: "d" is NOT promoted into the gap; the batch shrinks to two.
    #expect(store.items.map(\.id) == ["a", "c"])
    #expect(store.items.count == 2)

    // The per-kind fatigue count was persisted (all fixtures share one kind).
    try await waitUntil {
      let count =
        (try? await backend.insightDismissals.fetchAll())?
        .first { $0.kind == .netWorthMilestone }?.count
      return count == 1
    }
  }

  @Test("Show less rolls back the row and the fatigue bump on persist failure")
  func showLessRollsBackOnPersistFailure() async throws {
    let inner = try CloudKitAnalysisTestBackend()
    let backend = FailingDismissalBackend(inner: inner)
    let fixtures = [
      makeScoredInsight(id: "a", score: 4),
      makeScoredInsight(id: "b", score: 3),
      makeScoredInsight(id: "c", score: 2),
    ]
    let store = makeStore(backend, fixtures: fixtures)
    store.maxVisible = 3
    await store.refresh()
    #expect(store.items.map(\.id) == ["a", "b", "c"])

    let target = try #require(store.items.first { $0.id == "b" })
    await store.dismiss(target.scored)

    // The persist threw, so the optimistic mutation is rolled back: the row is
    // restored and the failure is surfaced.
    #expect(store.items.map(\.id) == ["a", "b", "c"])
    #expect(store.error != nil)

    // The fatigue bump must not survive: a fresh refresh re-detects the same
    // batch with no down-ranking from a phantom dismissal.
    store.overrideLastLoadedAtForTesting(nil)
    await store.refresh()
    #expect(store.items.map(\.id) == ["a", "b", "c"])
  }

  // MARK: - Polling helper

  private func waitUntil(
    timeout: Duration = .seconds(10),
    pollEvery: Duration = .milliseconds(20),
    _ condition: @MainActor () async -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if await condition() { return }
      try await Task.sleep(for: pollEvery)
    }
    if await condition() { return }
    throw TimeoutError()
  }

  private struct TimeoutError: Error {}
}

/// A `BackendProvider` that forwards everything to an inner
/// `CloudKitAnalysisTestBackend` except `insightDismissals`, which it swaps for
/// a repository whose `recordDismissal(of:)` always throws — so the
/// `dismiss(_:)` rollback path can be exercised.
private struct FailingDismissalBackend: BackendProvider, @unchecked Sendable {
  let inner: CloudKitAnalysisTestBackend
  let insightDismissals: any InsightDismissalRepository = FailingDismissalRepository()

  var auth: any AuthProvider { inner.auth }
  var accounts: any AccountRepository { inner.accounts }
  var accountGroups: any AccountGroupRepository { inner.accountGroups }
  var transactions: any TransactionRepository { inner.transactions }
  var categories: any CategoryRepository { inner.categories }
  var transferSuggestions: any TransferSuggestionRepository { inner.transferSuggestions }
  var earmarks: any EarmarkRepository { inner.earmarks }
  var analysis: any AnalysisRepository { inner.analysis }
  var insightDataSource: any InsightDataSource { inner.insightDataSource }
  var investments: any InvestmentRepository { inner.investments }
  var conversionService: any InstrumentConversionService { inner.conversionService }
  var csvImportProfiles: any CSVImportProfileRepository { inner.csvImportProfiles }
  var importRules: any ImportRuleRepository { inner.importRules }
  var walletSyncState: any WalletSyncStateRepository { inner.walletSyncState }
  var walletSyncCheckpoints: any WalletSyncCheckpointRepository { inner.walletSyncCheckpoints }
  var groupUIState: any GroupUIStateRepository { inner.groupUIState }
}

/// A dismissal repository whose write always throws and whose observation
/// streams stay empty — so the optimistic fatigue bump is never echoed back.
private struct FailingDismissalRepository: InsightDismissalRepository {
  struct PersistFailure: Error {}

  func fetchAll() async throws -> [InsightDismissal] { [] }

  func observeAll() -> AsyncStream<[InsightDismissal]> {
    AsyncStream { $0.finish() }
  }

  func observeErrors() -> AsyncStream<any Error> {
    AsyncStream { $0.finish() }
  }

  @discardableResult
  func recordDismissal(of kind: InsightKind) async throws -> InsightDismissal {
    throw PersistFailure()
  }
}

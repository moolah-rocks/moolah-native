import Foundation
import Testing

@testable import Moolah

/// Tests for `InsightStore`: the off-main build + on-main publish pipeline,
/// in-place re-rank on `dismiss(_:)`, and `refreshIfStale` staleness gating.
///
/// Sibling stores are constructed against a `CloudKitAnalysisTestBackend`
/// (mirroring `ProfileSession.makeDomainStores`) with `instrumentChanges: nil`
/// so no live registry observation runs during the test. The seed creates a
/// backlog of uncategorized posted transactions, which deterministically fires
/// the `uncategorizedBacklog` data-quality insight regardless of sibling-store
/// priming.
@MainActor
@Suite("InsightStore")
struct InsightStoreTests {
  private let aud = Instrument.defaultTestInstrument

  // MARK: - Harness

  private func makeProfile() -> Profile {
    Profile(label: "Test", currencyCode: "AUD", financialYearStartMonth: 7)
  }

  private func makeSources(_ backend: CloudKitAnalysisTestBackend) -> InsightStoreSources {
    InsightStoreSources(
      analysis: AnalysisStore(repository: backend.analysis),
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

  private func makeStore(_ backend: CloudKitAnalysisTestBackend) -> InsightStore {
    InsightStore(
      sources: makeSources(backend), backend: backend, profile: makeProfile(),
      instrumentChanges: nil)
  }

  private func makeStore(
    _ backend: CloudKitAnalysisTestBackend, fixtures: [ScoredInsight]
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

  /// Seeds `count` posted, fully-uncategorized transactions so the
  /// `uncategorizedBacklog` insight (threshold 10) fires deterministically.
  private func seedUncategorizedBacklog(
    _ backend: CloudKitAnalysisTestBackend, count: Int
  ) async throws {
    for index in 0..<count {
      _ = try await backend.transactions.create(
        Transaction(
          date: try AnalysisTestHelpers.utcDate(year: 2026, month: 5, day: 1),
          payee: "Merchant \(index)",
          legs: [
            TransactionLeg(
              accountId: nil, instrument: aud, quantity: -10, type: .expense, categoryId: nil)
          ]))
    }
  }

  // MARK: - refresh

  @Test("refresh builds and publishes insights")
  func refreshPublishesInsights() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    try await seedUncategorizedBacklog(backend, count: 12)
    let store = makeStore(backend)

    await store.refresh()

    #expect(!store.items.isEmpty)
    #expect(store.error == nil)
    #expect(store.isLoading == false)
    #expect(store.lastLoadedAt != nil)
    #expect(store.items.contains { $0.scored.insight.kind == .uncategorizedBacklog })
  }

  @Test
  func fixtureInsightsArePublishedAndDismissable() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let fixtures = [
      makeScoredInsight(id: "a", score: 3),
      makeScoredInsight(id: "b", score: 2),
    ]
    let store = makeStore(backend, fixtures: fixtures)

    await store.refresh()
    #expect(store.items.map(\.id) == ["a", "b"])

    await store.dismiss(try #require(store.items.first).scored)
    // No backfill: the dropped row's gap closes; the batch shrinks to one.
    #expect(store.items.map(\.id) == ["b"])
  }

  // MARK: - dismiss

  @Test
  func dismissRemovesInsightFromPublishedList() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    try await seedUncategorizedBacklog(backend, count: 12)
    let store = makeStore(backend)
    await store.refresh()

    let target = try #require(
      store.items.first { $0.scored.insight.kind == .uncategorizedBacklog })
    let loadedAtBeforeDismiss = store.lastLoadedAt

    await store.dismiss(target.scored)

    // The dismissed row is gone from the published batch immediately — and the
    // optimistic mutation is not a rebuild, so `lastLoadedAt` is untouched.
    #expect(!store.items.contains { $0.id == target.id })
    #expect(store.lastLoadedAt == loadedAtBeforeDismiss)
  }

  @Test
  func dismissedInsightStaysHiddenAcrossRefresh() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    try await seedUncategorizedBacklog(backend, count: 12)
    let store = makeStore(backend)
    await store.refresh()
    let target = try #require(
      store.items.first { $0.scored.insight.kind == .uncategorizedBacklog })

    await store.dismiss(target.scored)
    store.overrideLastLoadedAtForTesting(nil)  // force the next refresh to rebuild
    await store.refresh()

    // A full rebuild re-detects the backlog, but the session dismissal keeps
    // it hidden until relaunch (Phase D persists this across launches).
    #expect(!store.items.contains { $0.id == target.id })
  }

  // MARK: - refreshIfStale

  @Test("refreshIfStale skips a rebuild within the interval")
  func refreshIfStaleSkipsWithinInterval() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    try await seedUncategorizedBacklog(backend, count: 12)
    let store = makeStore(backend)
    await store.refresh()
    let firstLoadedAt = try #require(store.lastLoadedAt)

    // A very large interval means the recent load is still fresh — no rebuild.
    await store.refreshIfStale(minimumInterval: 10_000)

    #expect(store.lastLoadedAt == firstLoadedAt)
  }

  @Test("refreshIfStale rebuilds when stale")
  func refreshIfStaleRebuildsWhenStale() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    try await seedUncategorizedBacklog(backend, count: 12)
    let store = makeStore(backend)
    await store.refresh()
    let firstLoadedAt = try #require(store.lastLoadedAt)

    // Rewind the clock so the store considers itself stale.
    store.overrideLastLoadedAtForTesting(Date(timeIntervalSinceNow: -3600))
    await store.refreshIfStale(minimumInterval: 60)

    let secondLoadedAt = try #require(store.lastLoadedAt)
    #expect(secondLoadedAt > firstLoadedAt)
    #expect(!store.insights.isEmpty)
  }

  @Test("refreshIfStale always refreshes if nothing has been loaded yet")
  func refreshIfStaleLoadsWhenNeverRefreshed() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    try await seedUncategorizedBacklog(backend, count: 12)
    let store = makeStore(backend)

    // No prior refresh — `lastLoadedAt` is nil, so a very large interval must
    // not suppress the load.
    await store.refreshIfStale(minimumInterval: 10_000)

    #expect(store.lastLoadedAt != nil)
    #expect(!store.insights.isEmpty)
  }

  // MARK: - Earmark instrument filtering

  @Test("makeEarmarkSnapshots omits foreign-instrument earmarks")
  func earmarkSnapshotsOmitsForeignInstrument() async throws {
    let backend = try CloudKitAnalysisTestBackend()

    // Seed an AUD earmark (reporting instrument) — must appear in snapshot.
    let audEarmark = Earmark(
      name: "AUD Savings",
      instrument: .AUD,
      savingsGoal: InstrumentAmount(quantity: 1000, instrument: .AUD))
    _ = try await backend.earmarks.create(audEarmark)

    // Seed a USD earmark (foreign instrument) — must be omitted from snapshot.
    let usdEarmark = Earmark(
      name: "USD Travel Fund",
      instrument: .USD,
      savingsGoal: InstrumentAmount(quantity: 500, instrument: .USD))
    _ = try await backend.earmarks.create(usdEarmark)

    let sources = makeSources(backend)
    // Wait for the reactive EarmarkStore to observe both seeded earmarks before
    // InsightStore.refresh() reads the snapshot — avoids a race where the
    // snapshot sees an empty list.
    try await sources.earmark.waitForNextEmission(
      matching: {
        $0.earmarks.by(id: audEarmark.id) != nil
          && $0.earmarks.by(id: usdEarmark.id) != nil
      },
      description: "both earmarks observed")

    // Seed uncategorized transactions so the engine runs and the `refresh()`
    // pipeline exercises the full path.
    try await seedUncategorizedBacklog(backend, count: 12)

    let store = InsightStore(
      sources: sources, backend: backend, profile: makeProfile(),
      instrumentChanges: nil)
    await store.refresh()

    // Refresh must succeed without trapping on mismatched instruments.
    #expect(store.error == nil)
    #expect(store.isLoading == false)
    // The uncategorized-backlog insight fires, proving the engine ran against
    // the AUD earmark only (no USD-instrument trap in the snapshot).
    #expect(store.insights.contains { $0.insight.kind == .uncategorizedBacklog })
  }

  // MARK: - Persisted dismissals (observe + write-through)

  @Test("dismiss write-throughs the per-kind count to the repository")
  func dismissPersistsPerKindCount() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    try await seedUncategorizedBacklog(backend, count: 12)
    let store = makeStore(backend)
    await store.refresh()

    let target = try #require(
      store.items.first { $0.scored.insight.kind == .uncategorizedBacklog })
    await store.dismiss(target.scored)

    // The write-through fires in a detached `Task`; poll the repository until
    // the committed increment lands (no fixed sleep — bounded poll).
    try await waitUntil(timeout: .seconds(5)) {
      let count =
        (try? await backend.insightDismissals.fetchAll())?
        .first { $0.kind == .uncategorizedBacklog }?.count
      return count == 1
    }
  }

  @Test("a pre-existing persisted dismissal downranks that kind on refresh")
  func persistedDismissalsSeedFatigueOnRefresh() async throws {
    // Baseline: a fresh store with no dismissals — capture the
    // `.uncategorizedBacklog` score the ranker assigns with zero fatigue.
    let baselineBackend = try CloudKitAnalysisTestBackend()
    try await seedUncategorizedBacklog(baselineBackend, count: 12)
    let baselineStore = makeStore(baselineBackend)
    await baselineStore.refresh()
    let baselineScore = try #require(
      baselineStore.insights.first { $0.insight.kind == .uncategorizedBacklog }?.score)

    // A store atop a backend whose repository already records one dismissal of
    // `.uncategorizedBacklog`. The observation seeds the in-memory fatigue
    // table asynchronously, so poll-refresh until the persisted count reaches
    // the ranker and lowers the published score below the un-dismissed
    // baseline (fatigue penalty is strictly subtractive — any drop proves the
    // persisted count influenced the engine run).
    let backend = try CloudKitAnalysisTestBackend()
    try await seedUncategorizedBacklog(backend, count: 12)
    _ = try await backend.insightDismissals.recordDismissal(of: .uncategorizedBacklog)
    let store = makeStore(backend)

    try await waitUntil(timeout: .seconds(5)) {
      store.overrideLastLoadedAtForTesting(nil)  // force each poll to rebuild
      await store.refresh()
      guard
        let score = store.insights.first(where: {
          $0.insight.kind == .uncategorizedBacklog
        })?.score
      else { return false }
      return score < baselineScore
    }
  }

  // MARK: - Polling helper

  /// Polls `condition` on the main actor until it returns true or the timeout
  /// elapses, throwing `TimeoutError` otherwise. Used to wait on the async
  /// write-through / observation seam without a fixed sleep.
  private func waitUntil(
    timeout: Duration,
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

  // MARK: - Error path

  // FIX 8 (SKIPPED): `InsightInputBuilder.build()` drops failed conversions per
  // Rule 11 rather than throwing — so a conversion-service failure does not make
  // `build()` throw or set `store.error`. The error path in `refresh()` is
  // reached only by unexpected repository/DB failures, which `CloudKitAnalysisTestBackend`
  // does not expose an injection point for. No fabricated test added here.
}

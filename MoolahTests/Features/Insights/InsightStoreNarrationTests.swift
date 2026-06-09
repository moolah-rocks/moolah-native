import Foundation
import Testing

@testable import Moolah

/// Tests for `InsightStore`'s eager, batch-generated headlines: the visible
/// batch is published as `items` only once *every* member's headline resolves;
/// availability gating; per-insight fallback to the detector title on a
/// throwing narrator; and the session headline cache (issue #1042).
@MainActor
@Suite("InsightStore headlines")
struct InsightStoreNarrationTests {

  // MARK: - Harness

  private func makeProfile() -> Profile {
    Profile(label: "Test", currencyCode: "AUD", financialYearStartMonth: 7)
  }

  private func makeScoredInsight(id: String) -> ScoredInsight {
    ScoredInsight(
      insight: Insight(
        id: id,
        kind: .netWorthMilestone,
        title: "Net worth crossed $100k",
        date: Date(timeIntervalSince1970: 1_700_000_000),
        framing: .positive,
        actionability: .informational,
        surprise: 0.3,
        facts: [InsightFact("Now", "$101,200")]),
      score: 2.0)
  }

  private func makeStore(
    availability: ModelAvailability,
    narrator: any InsightNarrating,
    fixtures: [ScoredInsight]
  ) throws -> InsightStore {
    let backend = try CloudKitAnalysisTestBackend()
    let aud = Instrument.defaultTestInstrument
    let sources = InsightStoreSources(
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
    return InsightStore(
      sources: sources,
      backend: backend,
      profile: makeProfile(),
      instrumentChanges: nil,
      availability: FixedModelAvailability(value: availability),
      narrator: narrator,
      fixtureInsights: InsightFixtures(insights: fixtures))
  }

  // MARK: - batch members carry their narrated headline

  @Test("all batch members carry their narrated headline after refresh")
  func allBatchMembersCarryNarratedHeadlineAfterRefresh() async throws {
    let store = try makeStore(
      availability: .available,
      narrator: ScriptedNarrator(snapshots: ["Din", "Dining is up."]),
      fixtures: [makeScoredInsight(id: "a"), makeScoredInsight(id: "b")])

    await store.refresh()

    #expect(store.items.map(\.id) == ["a", "b"])
    #expect(store.items.allSatisfy { $0.headline == "Dining is up." })
  }

  // MARK: - per-insight fallback to title

  @Test("a throwing narrator falls every headline back to the detector title")
  func guardFailureFallsBackToTitle() async throws {
    let fixtures = [makeScoredInsight(id: "a"), makeScoredInsight(id: "b")]
    let store = try makeStore(
      availability: .available,
      narrator: ThrowingNarrator(),
      fixtures: fixtures)

    await store.refresh()

    // The batch is still published — fallback is per-insight, never an empty card.
    #expect(store.items.map(\.id) == ["a", "b"])
    for item in store.items {
      #expect(item.headline == item.scored.insight.title)
    }
  }

  // MARK: - availability off

  @Test("model unavailable uses the detector title without calling the narrator")
  func availabilityOffUsesTitle() async throws {
    let narrator = CountingNarrator(snapshot: "Should not appear.")
    let store = try makeStore(
      availability: .unavailable(.deviceNotEligible),
      narrator: narrator,
      fixtures: [makeScoredInsight(id: "a")])

    await store.refresh()

    let item = try #require(store.items.first)
    #expect(item.headline == item.scored.insight.title)
    #expect(narrator.callCount == 0)
  }

  // MARK: - session cache

  @Test("a cache hit skips regeneration across two refreshes")
  func cacheHitSkipsRegeneration() async throws {
    let narrator = CountingNarrator(snapshot: "Cached headline.")
    let store = try makeStore(
      availability: .available,
      narrator: narrator,
      fixtures: [makeScoredInsight(id: "a"), makeScoredInsight(id: "b")])

    await store.refresh()
    #expect(store.items.allSatisfy { $0.headline == "Cached headline." })

    store.overrideLastLoadedAtForTesting(nil)
    await store.refresh()

    // Two ids, resolved once each — the second refresh is fully cache-served.
    #expect(narrator.callCount == 2)
  }
}

/// A narrator that emits a single fixed snapshot and counts how many times it
/// is asked to narrate — so a test can prove the session headline cache avoids
/// re-running the narrator for an already-resolved insight.
private final class CountingNarrator: InsightNarrating, @unchecked Sendable {
  private let snapshot: String
  private let lock = NSLock()
  private var count = 0

  init(snapshot: String) {
    self.snapshot = snapshot
  }

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  nonisolated func narrate(_ request: NarrationRequest) -> AsyncThrowingStream<String, any Error> {
    lock.lock()
    count += 1
    lock.unlock()
    let snapshot = self.snapshot
    return AsyncThrowingStream { continuation in
      continuation.yield(snapshot)
      continuation.finish()
    }
  }
}

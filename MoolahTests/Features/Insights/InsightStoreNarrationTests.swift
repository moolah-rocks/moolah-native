import Foundation
import Testing

@testable import Moolah

/// Tests for `InsightStore`'s narration cache: availability gating,
/// streaming → done lifecycle, fallback to template, and cancellation
/// (issue #1042).
@MainActor
@Suite("InsightStore narration")
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
    narrator: any InsightNarrating
  ) throws -> InsightStore {
    let backend = try CloudKitAnalysisTestBackend()
    let aud = Instrument.defaultTestInstrument
    let sources = InsightStoreSources(
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
    return InsightStore(
      sources: sources,
      backend: backend,
      profile: makeProfile(),
      instrumentChanges: nil,
      availability: FixedModelAvailability(value: availability),
      narrator: narrator,
      fixtureInsights: InsightFixtures(insights: [makeScoredInsight(id: "test-insight")]))
  }

  // MARK: - narrate: available + scripted narrator

  @Test("narrate streams then caches as done")
  func narrateStreamsThenCaches() async throws {
    let store = try makeStore(
      availability: .available,
      narrator: ScriptedNarrator(snapshots: ["Din", "Dining is up."]))
    await store.refresh()
    let insight = try #require(store.insights.first)

    store.narrate(insight)
    await store.narrationTasks[insight.id]?.value

    #expect(store.narration[insight.id] == .done("Dining is up."))
  }

  @Test("second narrate call is a no-op when already done")
  func narrateSecondCallIsNoop() async throws {
    let store = try makeStore(
      availability: .available,
      narrator: ScriptedNarrator(snapshots: ["First result."]))
    await store.refresh()
    let insight = try #require(store.insights.first)

    store.narrate(insight)
    await store.narrationTasks[insight.id]?.value
    #expect(store.narration[insight.id] == .done("First result."))

    // Second call with a different narrator result should NOT replace the cache.
    store.narrate(insight)
    #expect(store.narration[insight.id] == .done("First result."))
  }

  // MARK: - narrate: fallback on error

  @Test("throwing narrator falls back to template text")
  func guardFailureFallsBackToTemplate() async throws {
    let store = try makeStore(
      availability: .available,
      narrator: ThrowingNarrator())
    await store.refresh()
    let insight = try #require(store.insights.first)

    store.narrate(insight)
    await store.narrationTasks[insight.id]?.value

    if case .fellBackToTemplate(let text) = store.narration[insight.id] {
      #expect(!text.isEmpty)
      // Template output is the title for a singleInsight request.
      #expect(text == insight.insight.title)
    } else {
      Issue.record(
        "expected .fellBackToTemplate, got \(String(describing: store.narration[insight.id]))")
    }
  }

  // MARK: - narrate: unavailable model

  @Test("narrate is a no-op when model is unavailable")
  func narrateIsNoopWhenUnavailable() async throws {
    let store = try makeStore(
      availability: .unavailable(.deviceNotEligible),
      narrator: ScriptedNarrator(snapshots: ["Should not appear."]))
    await store.refresh()
    let insight = try #require(store.insights.first)

    store.narrate(insight)

    // The narration dict must remain empty (no entry at all) when unavailable.
    #expect(store.narration[insight.id] == nil)
  }

  // MARK: - cancelNarration

  @Test("cancelNarration after completion is a no-op — preserves cached result")
  func cancelNarrationAfterCompletionIsNoop() async throws {
    let store = try makeStore(
      availability: .available,
      narrator: ScriptedNarrator(snapshots: ["Done."]))
    await store.refresh()
    let insight = try #require(store.insights.first)

    store.narrate(insight)
    await store.narrationTasks[insight.id]?.value
    #expect(store.narration[insight.id] == .done("Done."))

    // cancelNarration is a no-op once the task has completed: the task dict
    // entry is already removed by the defer, so the guard exits early and
    // the cached .done result is preserved.
    store.cancelNarration(insight.id)

    #expect(store.narration[insight.id] == .done("Done."))
  }
}

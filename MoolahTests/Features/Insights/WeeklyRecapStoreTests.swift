import Foundation
import Testing

@testable import Moolah

/// Tests for `WeeklyRecapStore`: opt-in gate, availability gate, ISO-week
/// gate, narration → `.ready`, template fallback on error, and dismiss
/// behaviour (issue #1042).
///
/// All tests use:
/// - `InMemoryRecapLastShownStore` (in-memory persistence seam — no
///   `UserDefaults` side effects)
/// - `isOptedIn` closure injection (no shared `UserDefaults` reads)
/// - Fixed `now` closure (no `Date()` inside pure logic)
/// - `ScriptedNarrator` or `ThrowingNarrator` (no real model)
/// - `FixedModelAvailability` (no `SystemLanguageModel` call)
@MainActor
@Suite("WeeklyRecapStore")
struct WeeklyRecapStoreTests {

  // MARK: - Harness

  /// A fixed "now" well into a week so timezone jitter doesn't push it
  /// across a week boundary: 2024-01-03 12:00 UTC (Wednesday of W01).
  private let fixedNow = Date(timeIntervalSince1970: 1_704_283_200)

  /// Previous week: 2023-12-27 12:00 UTC (Wednesday of W52).
  private let lastWeek = Date(timeIntervalSince1970: 1_703_678_400)

  private func makeInsightStore(fixtures: [ScoredInsight] = [makeScoredInsight()]) throws
    -> InsightStore
  {
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
      sources: sources, backend: backend,
      profile: Profile(label: "Test", currencyCode: "AUD", financialYearStartMonth: 7),
      instrumentChanges: nil,
      fixtureInsights: InsightFixtures(insights: fixtures))
  }

  private static func makeScoredInsight(id: String = "test-1") -> ScoredInsight {
    ScoredInsight(
      insight: Insight(
        id: id, kind: .netWorthMilestone, title: "Net worth hit $100k",
        detail: "Nice milestone.", date: Date(timeIntervalSince1970: 1_700_000_000),
        framing: .positive, actionability: .informational, surprise: 0.3,
        facts: [InsightFact("Now", "$100,000")]),
      score: 2.0)
  }

  private func makeStore(
    insightStore: InsightStore,
    narrator: any InsightNarrating = ScriptedNarrator(snapshots: ["Great week."]),
    availability: ModelAvailability = .available,
    lastShownStore: InMemoryRecapLastShownStore = InMemoryRecapLastShownStore(),
    isOptedIn: @escaping @Sendable () -> Bool = { true },
    now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_704_283_200) }
  ) -> WeeklyRecapStore {
    WeeklyRecapStore(
      insightStore: insightStore,
      narrator: narrator,
      availability: FixedModelAvailability(value: availability),
      lastShownStore: lastShownStore,
      profileId: UUID(),
      isOptedIn: isOptedIn,
      now: now)
  }

  // MARK: - prepareIfDue: happy path

  @Test("opted-in, available, new week, with insights → .ready and records the week")
  func happyPathReturnsReady() async throws {
    let insightStore = try makeInsightStore()
    await insightStore.refresh()
    let lastShownStore = InMemoryRecapLastShownStore()
    let store = makeStore(
      insightStore: insightStore,
      narrator: ScriptedNarrator(snapshots: ["Great week."]),
      availability: .available,
      lastShownStore: lastShownStore,
      isOptedIn: { true },
      now: { Date(timeIntervalSince1970: 1_704_283_200) }
    )

    await store.prepareIfDue()

    if case .ready(let text) = store.recap {
      #expect(text == "Great week.")
    } else {
      Issue.record("Expected .ready, got \(store.recap)")
    }
    // The shown-week must be recorded so a second call in the same week is a no-op.
    let profileId = store.profileId
    #expect(lastShownStore.lastShown(forProfile: profileId) != nil)
  }

  // MARK: - prepareIfDue: opt-in off

  @Test("opt-in off → .hidden")
  func optInOffStaysHidden() async throws {
    let insightStore = try makeInsightStore()
    await insightStore.refresh()
    let store = makeStore(
      insightStore: insightStore,
      narrator: ScriptedNarrator(snapshots: ["Should not appear."]),
      availability: .available,
      isOptedIn: { false }
    )

    await store.prepareIfDue()

    // .hidden means the narrator was not called (or call was short-circuited
    // before narration) — any narrator invocation would produce .ready("…").
    #expect(store.recap == .hidden)
  }

  // MARK: - prepareIfDue: unavailable

  @Test("availability unavailable → .hidden")
  func unavailableStaysHidden() async throws {
    let insightStore = try makeInsightStore()
    await insightStore.refresh()
    let store = makeStore(
      insightStore: insightStore,
      availability: .unavailable(.deviceNotEligible),
      isOptedIn: { true }
    )

    await store.prepareIfDue()

    #expect(store.recap == .hidden)
  }

  // MARK: - prepareIfDue: same week

  @Test("same week as last shown → .hidden")
  func sameWeekStaysHidden() async throws {
    let insightStore = try makeInsightStore()
    await insightStore.refresh()
    let lastShownStore = InMemoryRecapLastShownStore()
    let profileId = UUID()
    // Record the same fixed week as "already shown".
    let sameWeekDate = Date(timeIntervalSince1970: 1_704_283_200)
    lastShownStore.setLastShown(sameWeekDate, forProfile: profileId)

    let store = WeeklyRecapStore(
      insightStore: insightStore,
      narrator: ScriptedNarrator(snapshots: ["Should not appear."]),
      availability: FixedModelAvailability(value: .available),
      lastShownStore: lastShownStore,
      profileId: profileId,
      isOptedIn: { true },
      now: { Date(timeIntervalSince1970: 1_704_283_200) })

    await store.prepareIfDue()

    #expect(store.recap == .hidden)
  }

  // MARK: - prepareIfDue: no insights

  @Test("no insights → .hidden")
  func noInsightsStaysHidden() async throws {
    let insightStore = try makeInsightStore(fixtures: [])
    await insightStore.refresh()
    let store = makeStore(insightStore: insightStore, isOptedIn: { true })

    await store.prepareIfDue()

    #expect(store.recap == .hidden)
  }

  // MARK: - prepareIfDue: narrator throws → template fallback

  @Test("narrator throws → .ready with template text")
  func narratorThrowsFallsBackToTemplate() async throws {
    let insightStore = try makeInsightStore()
    await insightStore.refresh()
    let store = makeStore(
      insightStore: insightStore,
      narrator: ThrowingNarrator(),
      availability: .available,
      isOptedIn: { true }
    )

    await store.prepareIfDue()

    if case .ready(let text) = store.recap {
      #expect(!text.isEmpty)
    } else {
      Issue.record("Expected .ready(fallback), got \(store.recap)")
    }
  }

  // MARK: - dismiss

  @Test("dismiss → .hidden, does not clear the recorded shown week")
  func dismissHidesButKeepsRecord() async throws {
    let insightStore = try makeInsightStore()
    await insightStore.refresh()
    let lastShownStore = InMemoryRecapLastShownStore()
    let store = makeStore(
      insightStore: insightStore,
      narrator: ScriptedNarrator(snapshots: ["Great week."]),
      availability: .available,
      lastShownStore: lastShownStore,
      isOptedIn: { true }
    )

    await store.prepareIfDue()
    #expect(store.recap != .hidden)

    store.dismiss()

    #expect(store.recap == .hidden)
    // The shown-week record must still exist so a re-open in the same week stays hidden.
    let profileId = store.profileId
    #expect(lastShownStore.lastShown(forProfile: profileId) != nil)
  }
}

// MARK: - Test doubles

/// In-memory implementation of `RecapLastShownStoring`. Thread-safe for
/// `@MainActor`-confined tests; not intended for concurrent production use.
final class InMemoryRecapLastShownStore: RecapLastShownStoring {
  private var storage: [UUID: Date] = [:]

  func lastShown(forProfile profileId: UUID) -> Date? {
    storage[profileId]
  }

  func setLastShown(_ date: Date, forProfile profileId: UUID) {
    storage[profileId] = date
  }
}

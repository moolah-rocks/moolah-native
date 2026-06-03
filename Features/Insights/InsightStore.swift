import Foundation
import OSLog
import Observation

/// UI-testing seam payload: a non-optional fixture list wrapped so the store can
/// pass and hold it as an `Optional` (nil = production / preview) without
/// tripping SwiftLint's `discouraged_optional_collection` on a bare
/// `[ScoredInsight]?` init parameter / stored property.
struct InsightFixtures: Sendable {
  let insights: [ScoredInsight]
}

/// Default availability provider used when no provider is injected — always
/// returns `.unavailable(.deviceNotEligible)` so no narration surface lights
/// up in previews, legacy tests, or any path that doesn't explicitly wire a
/// real provider. Distinct from `FixedModelAvailability` (which is DEBUG-only)
/// so this struct compiles in release builds where `#if DEBUG` is stripped.
private struct NeverAvailableModelAvailability: ModelAvailabilityProviding {
  @MainActor
  func current() -> ModelAvailability { .unavailable(.deviceNotEligible) }
}

/// The sibling feature stores `InsightStore` reads each refresh to gather the
/// main-actor half of an `InsightInput` (the `InsightInputSnapshot`). Bundled
/// into a single struct so `InsightStore.init` stays within SwiftLint's
/// `function_parameter_count` budget (≤5); the bundle itself groups the 6
/// store references. `@MainActor` because every member is a main-actor store
/// and the snapshot is gathered on the main actor.
@MainActor
struct InsightStoreSources {
  let analysis: AnalysisStore
  let earmark: EarmarkStore
  let reporting: ReportingStore
  let account: AccountStore
  /// Optional because `ProfileSession` assigns `accountGroupStore` in
  /// `finishInit` and degraded (preview) launches may omit it.
  let accountGroup: AccountGroupStore?
  let category: CategoryStore
}

/// Owns the "For You" insight surface state: builds the `InsightInput` off the
/// main actor, runs the pure `InsightEngine`, and publishes the ranked result.
///
/// ## Refresh model
/// This codebase has **no transaction-data change tick** a store can subscribe
/// to — the sibling analysis stores (`AnalysisStore`, `ReportingStore`) reload
/// via view-driven `loadAll()` / `refreshIfStale`. `InsightStore` follows the
/// same contract: new-transaction recomputation rides the view-driven
/// `refreshIfStale(minimumInterval:)` the surface calls (not a rebuild on every
/// appearance). The one tick available is the instrument registry's
/// `observeChanges()` stream — instrument/currency-metadata edits **do** affect
/// insight conversions, so those trigger an immediate tick-driven `refresh()`.
///
/// Detected insights are cached as `lastInput`, so `dismiss(_:)` re-ranks the
/// already-built input instantly without rebuilding off the main actor.
@Observable
@MainActor
final class InsightStore {

  // MARK: - State

  private(set) var insights: [ScoredInsight] = []
  private(set) var isLoading = false
  private(set) var error: Error?

  /// Timestamp of the last successful `refresh()`. Used by `refreshIfStale`
  /// to skip a rebuild when data was fetched recently (mirrors
  /// `AnalysisStore.lastLoadedAt`).
  private(set) var lastLoadedAt: Date?

  // MARK: - Dependencies

  private let sources: InsightStoreSources
  private let builder: InsightInputBuilder
  private let engine: InsightEngine
  /// The reporting currency every monetary input is reduced to.
  private let reportingInstrument: Instrument

  /// Narrow seam onto the shared instrument registry's change stream. Nil in
  /// previews / legacy tests so no live observation runs.
  private let instrumentChanges: (any InstrumentChangeObserving)?

  /// Current model eligibility for the on-device narration layer. Defaults to
  /// `.unavailable(.deviceNotEligible)` (via `NeverAvailableModelAvailability`)
  /// when no provider is injected — previews/tests see nothing lit up by accident.
  /// Consumed by E3 (`narrate(_:)`) to gate narration requests; stored here so
  /// the view can read `availability.current()` to show/hide the "Why?" button.
  let availability: any ModelAvailabilityProviding

  /// UI-testing seam: when non-nil, `refresh()` publishes these fixtures
  /// instead of building an `InsightInput` and running the engine — so a
  /// `MoolahUITests_macOS` seed can assert the surface deterministically
  /// (mirrors the `transferDetectionBaseline` "write the result directly"
  /// pattern). Nil in production and previews. `dismiss(_:)` still works via
  /// `dismissedIds` because the fixture path leaves `lastInput` nil.
  private let fixtureInsights: InsightFixtures?

  private let logger = Logger(subsystem: "com.moolah.app", category: "InsightStore")

  // MARK: - Cached / mutable

  /// In-memory dismissal counts per insight kind. Each `dismiss(_:)` bumps the
  /// kind's count; the ranker's fatigue penalty downranks it. Not persisted —
  /// dismissal telemetry is a future PR.
  private var dismissals: [InsightKind: Int] = [:]

  /// Ids dismissed in this session. Filtered out of every published list so a
  /// dismissed insight stays gone until relaunch. Distinct from `dismissals`,
  /// which counts dismissals *per kind* to drive the ranker's fatigue penalty;
  /// Phase D persists both across launches.
  private var dismissedIds: Set<String> = []

  /// The most recently-built `InsightInput`. Cached so `dismiss(_:)` re-ranks
  /// without rebuilding off the main actor.
  private var lastInput: InsightInput?

  /// Observes `instrumentChanges.observeChanges()` and re-refreshes on each
  /// tick. Spawned from `init` when a registry seam is wired; torn down by
  /// `stopObserving()` / `deinit`.
  private var instrumentChangeObservationTask: Task<Void, Never>?

  // MARK: - Lifecycle

  init(
    sources: InsightStoreSources,
    backend: any BackendProvider,
    profile: Profile,
    instrumentChanges: (any InstrumentChangeObserving)? = nil,
    availability: (any ModelAvailabilityProviding)? = nil,
    fixtureInsights: InsightFixtures? = nil
  ) {
    self.sources = sources
    self.builder = InsightInputBuilder(backend: backend)
    self.engine = InsightEngine()
    self.reportingInstrument = profile.instrument
    self.instrumentChanges = instrumentChanges
    // Default to ineligible when no provider is injected so no narration
    // surface lights up in previews/tests by accident. Production wires
    // `SystemLanguageModelAvailability()` from `ProfileSession.finishInit`.
    self.availability = availability ?? NeverAvailableModelAvailability()
    self.fixtureInsights = fixtureInsights

    // Strong `self` capture mirrors `EarmarkStore`: the store is
    // `@MainActor`, the task already holds an implicit strong reference, and
    // `stopObserving()` (from `cleanupSync`) is the sole lifetime gate.
    if let instrumentChanges {
      let changes = instrumentChanges.observeChanges()
      instrumentChangeObservationTask = Task { [self] in
        await self.observeInstrumentRegistryChanges(changes)
      }
    }
  }

  deinit {
    // Safety net for tear-down paths that miss `cleanupSync`. Swift 6 makes
    // `deinit` nonisolated; reading `@MainActor` state needs
    // `MainActor.assumeIsolated`. The store is owned by main-actor code
    // (`ProfileSession`), so the assumption holds.
    MainActor.assumeIsolated {
      instrumentChangeObservationTask?.cancel()
    }
  }

  /// Tears down the instrument-change observation task. Idempotent. Called
  /// from `ProfileSession.cleanupSync(coordinator:)`.
  func stopObserving() {
    instrumentChangeObservationTask?.cancel()
  }

  // MARK: - Refresh

  /// Rebuilds the `InsightInput` off the main actor and republishes the ranked
  /// insights. Mirrors `AnalysisStore.loadAll()`'s loading / cancellation /
  /// error handling.
  func refresh() async {
    guard !isLoading else { return }
    if let fixtureInsights {
      insights = visible(fixtureInsights.insights)
      lastLoadedAt = Date()
      return
    }
    let snapshot = makeSnapshot()
    let context = makeContext()
    isLoading = true
    defer { isLoading = false }
    error = nil

    do {
      let (input, scored) = try await compute(
        snapshot: snapshot, context: context, dismissals: dismissals)
      lastInput = input
      insights = visible(scored)
      lastLoadedAt = Date()
    } catch is CancellationError {
      // Surface refresh superseded / view torn down — never surface; a
      // re-mount issues its own `refresh()`. Mirrors `AnalysisStore`.
      return
    } catch {
      logger.error("Failed to build insights: \(error)")
      self.error = error
    }
  }

  /// Refreshes only if at least `minimumInterval` seconds have elapsed since
  /// the last successful `refresh()`. Always refreshes if nothing is loaded
  /// yet. Mirrors `AnalysisStore.refreshIfStale(minimumInterval:)`.
  func refreshIfStale(minimumInterval: TimeInterval) async {
    if let last = lastLoadedAt,
      Date().timeIntervalSince(last) < minimumInterval
    {
      return
    }
    await refresh()
  }

  /// Test hook: rewind `lastLoadedAt` to simulate staleness without waiting
  /// real time. Mirrors `AnalysisStore.overrideLastLoadedAtForTesting`.
  func overrideLastLoadedAtForTesting(_ date: Date?) {
    lastLoadedAt = date
  }

  // MARK: - Dismissal

  /// Removes the insight from the published list immediately and records a
  /// per-kind dismissal so the ranker's fatigue penalty downranks the kind for
  /// the rest of the session. Re-ranks the cached input in place (no rebuild)
  /// so any surviving insights reflect the new fatigue; falls back to filtering
  /// the current list when no input is cached.
  func dismiss(_ insight: ScoredInsight) {
    dismissedIds.insert(insight.id)
    dismissals[insight.insight.kind, default: 0] += 1
    if let lastInput {
      insights = visible(engine.generate(lastInput, dismissals: dismissals))
    } else {
      insights = visible(insights)
    }
  }

  /// Drops session-dismissed ids from a ranked list before publishing.
  private func visible(_ scored: [ScoredInsight]) -> [ScoredInsight] {
    scored.filter { !dismissedIds.contains($0.id) }
  }

  // MARK: - Compute (off-main)

  /// Builds the input and runs the engine off the main actor. `nonisolated`
  /// so the heavy `builder.build` and pure `engine.generate` run off
  /// `@MainActor`; the caller publishes the result on the main actor.
  /// `dismissals` is passed in (a `Sendable` snapshot) rather than read off
  /// `self`, so this stays free of main-actor isolation.
  nonisolated private func compute(
    snapshot: InsightInputSnapshot,
    context: InsightContext,
    dismissals: [InsightKind: Int]
  ) async throws -> (InsightInput, [ScoredInsight]) {
    let input = try await builder.build(snapshot: snapshot, context: context)
    let scored = engine.generate(input, dismissals: dismissals)
    return (input, scored)
  }

  /// Consumes the shared instrument registry's change stream. Each tick
  /// re-refreshes so conversion-dependent insights re-derive. `Task.isCancelled`
  /// is re-checked before and after each suspension so a teardown racing a tick
  /// exits before issuing a rebuild and promptly after a long in-flight refresh.
  /// Mirrors `EarmarkStore`.
  private func observeInstrumentRegistryChanges(_ changes: AsyncStream<Void>) async {
    for await _ in changes {
      if Task.isCancelled { return }
      await refresh()
      if Task.isCancelled { return }
    }
  }

}

// MARK: - Snapshot / context assembly (main actor)

extension InsightStore {
  /// Gathers the main-actor half of `InsightInput` from the sibling stores.
  private func makeSnapshot() -> InsightInputSnapshot {
    InsightInputSnapshot(
      monthly: sources.analysis.incomeAndExpense,
      expenseBreakdown: sources.analysis.expenseBreakdown,
      dailyBalances: sources.analysis.dailyBalances,
      earmarks: makeEarmarkSnapshots(),
      profitLoss: sources.reporting.profitLoss,
      capitalGains: sources.reporting.capitalGainsResult?.events ?? [],
      categories: sources.category.categories,
      accountGroups: (sources.accountGroup?.groups ?? []).map {
        InsightAccountGroup(id: $0.id, name: $0.name)
      },
      accountGroupMembership: makeAccountGroupMembership())
  }

  private func makeContext() -> InsightContext {
    InsightContext(
      now: Date(),
      reportingCurrency: reportingInstrument,
      financialMonthEnd: sources.analysis.monthEnd)
  }

  /// `accountId → groupId` map for every grouped account.
  private func makeAccountGroupMembership() -> [UUID: UUID] {
    var membership: [UUID: UUID] = [:]
    for account in sources.account.accounts.ordered {
      if let groupId = account.groupId {
        membership[account.id] = groupId
      }
    }
    return membership
  }

  /// Joins each same-reporting-currency `Earmark` with its converted balances
  /// from `EarmarkStore`.
  ///
  /// Foreign-instrument earmarks are intentionally omitted (Rule 11 — never
  /// mislabel native-instrument amounts as reporting currency): the dicts in
  /// `EarmarkStore` are in each earmark's **own** instrument, not the reporting
  /// instrument, so including them would mix instruments and risk a trap. This
  /// is the deliberate, documented degradation until `EarmarkStore` exposes
  /// per-earmark reporting-currency totals.
  ///
  /// Remaining deliberate degradation:
  /// - `budget: nil` — the per-earmark budget total is not yet reduced to the
  ///   reporting currency, so it is omitted rather than guessed.
  private func makeEarmarkSnapshots() -> [EarmarkSnapshot] {
    let zero = InstrumentAmount.zero(instrument: reportingInstrument)
    return sources.earmark.earmarks.compactMap { earmark in
      guard earmark.instrument == reportingInstrument else { return nil }
      return EarmarkSnapshot(
        id: earmark.id,
        name: earmark.name,
        balance: sources.earmark.convertedBalances[earmark.id] ?? zero,
        spent: sources.earmark.convertedSpentAmounts[earmark.id],
        budget: nil,
        savingsGoal: earmark.savingsGoal,
        saved: sources.earmark.convertedSavedAmounts[earmark.id],
        savingsStartDate: earmark.savingsStartDate,
        savingsEndDate: earmark.savingsEndDate,
        isHidden: earmark.isHidden)
    }
  }
}

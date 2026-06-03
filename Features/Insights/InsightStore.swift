import Foundation
import OSLog
import Observation

/// Default availability provider used when no provider is injected — always
/// returns `.unavailable(.deviceNotEligible)` so no narration surface lights
/// up in previews, legacy tests, or any path that doesn't explicitly wire a
/// real provider. Distinct from `FixedModelAvailability` (which is DEBUG-only)
/// so this struct compiles in release builds where `#if DEBUG` is stripped.
private struct NeverAvailableModelAvailability: ModelAvailabilityProviding, Sendable {
  @MainActor
  func current() -> ModelAvailability { .unavailable(.deviceNotEligible) }
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
  /// Persisted per-`InsightKind` dismissal tallies. Observed to seed the
  /// in-memory fatigue table and written through on each `dismiss(_:)`.
  private let dismissalRepository: any InsightDismissalRepository
  /// The reporting currency every monetary input is reduced to.
  private let reportingInstrument: Instrument

  /// Narrow seam onto the shared instrument registry's change stream. Nil in
  /// previews / legacy tests so no live observation runs.
  private let instrumentChanges: (any InstrumentChangeObserving)?

  /// Backing provider for on-device model eligibility. Defaults to
  /// `.unavailable(.deviceNotEligible)` (via `NeverAvailableModelAvailability`)
  /// when no provider is injected — previews/tests see nothing lit up by accident.
  private let availability: any ModelAvailabilityProviding

  /// Current model eligibility, for the narration UI to gate on. Exposes the
  /// value rather than the provider so callers don't reach into the seam.
  var currentAvailability: ModelAvailability { availability.current() }

  /// Narrator used to produce prose from a `NarrationRequest`. Defaults to
  /// `TemplateNarrator` (deterministic, no model) when no narrator is injected.
  /// Production injects `FoundationModelsNarrator` via `ProfileSession.finishInit`.
  /// Module-internal so `InsightStore+Narration.swift` can call it across the
  /// file boundary — not intended as API for any other type.
  let narrator: any InsightNarrating

  // MARK: - Narration state

  /// Per-insight narration state, keyed by `ScoredInsight.id`. Published so
  /// `ForYouCard` can render streaming partial text and the final result.
  /// Entries are set to `.idle` on `cancelNarration(_:)` and absent until the
  /// first `narrate(_:)` call for that insight. Module-internal (not private)
  /// so `InsightStore+Narration.swift` can write to it across the file boundary
  /// — treat as read-only from every other call site.
  var narration: [String: NarrationState] = [:]

  /// Live narration tasks keyed by insight id. Stored so they can be cancelled
  /// individually (`cancelNarration`) or all at once on teardown (mirrors the
  /// `instrumentChangeObservationTask` pattern). Module-internal for the same
  /// cross-file reason as `narration`.
  var narrationTasks: [String: Task<Void, Never>] = [:]

  /// UI-testing seam: when non-nil, `refresh()` publishes these fixtures
  /// instead of building an `InsightInput` and running the engine — so a
  /// `MoolahUITests_macOS` seed can assert the surface deterministically
  /// (mirrors the `transferDetectionBaseline` "write the result directly"
  /// pattern). Nil in production and previews. `dismiss(_:)` still works via
  /// `dismissedIds` because the fixture path leaves `lastInput` nil.
  private let fixtureInsights: InsightFixtures?

  private let logger = Logger(subsystem: "com.moolah.app", category: "InsightStore")

  // MARK: - Cached / mutable

  /// In-memory projection of the persisted per-kind dismissal counts
  /// (`InsightDismissalRepository`). Seeded and kept current by
  /// `observePersistedDismissals`; `dismiss(_:)` bumps it optimistically and
  /// write-throughs to the repo. Drives the ranker's fatigue penalty.
  private var dismissals: [InsightKind: Int] = [:]

  /// Ids dismissed in this session. Filtered from every published list so a
  /// dismissed card stays gone until relaunch. Deliberately session-only:
  /// these ids reference specific insights that age out (e.g. a transaction
  /// anomaly whose transaction leaves the window), so persisting them would
  /// be unbounded and brittle. The *kind*-level fatigue (above) is what
  /// persists and syncs.
  private var dismissedIds: Set<String> = []

  /// The most recently-built `InsightInput`. Cached so `dismiss(_:)` re-ranks
  /// without rebuilding off the main actor.
  private var lastInput: InsightInput?

  /// Observes `instrumentChanges.observeChanges()` and re-refreshes on each
  /// tick. Spawned from `init` when a registry seam is wired; torn down by
  /// `stopObserving()` / `deinit`.
  private var instrumentChangeObservationTask: Task<Void, Never>?

  /// Observes persisted per-kind dismissal counts (tally stream + error
  /// stream, drained in parallel). Each tally emission max-merges into
  /// `dismissals` (initial load on launch, local write-through echo, and
  /// remote sync) and re-ranks the cached input so the fatigue penalty stays
  /// current. Torn down by `stopObserving()` / `deinit`.
  private var dismissalObservationTask: Task<Void, Never>?

  // MARK: - Lifecycle

  init(
    sources: InsightStoreSources,
    backend: any BackendProvider,
    profile: Profile,
    instrumentChanges: (any InstrumentChangeObserving)? = nil,
    availability: (any ModelAvailabilityProviding)? = nil,
    narrator: (any InsightNarrating)? = nil,
    fixtureInsights: InsightFixtures? = nil
  ) {
    self.sources = sources
    self.builder = InsightInputBuilder(backend: backend)
    self.engine = InsightEngine()
    self.dismissalRepository = backend.insightDismissals
    self.reportingInstrument = profile.instrument
    self.instrumentChanges = instrumentChanges
    // Default to ineligible when no provider is injected so no narration
    // surface lights up in previews/tests by accident.
    self.availability = availability ?? NeverAvailableModelAvailability()
    self.narrator = narrator ?? TemplateNarrator()
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

    // Capture BOTH streams locally (mirrors `EarmarkStore.observe()`): the
    // region-based isolation checker can reason about the `Sendable` streams
    // when they are captured outside the `addTask` closures.
    let dismissalStream = dismissalRepository.observeAll()
    let dismissalErrors = dismissalRepository.observeErrors()
    dismissalObservationTask = Task { [self] in
      await self.observePersistedDismissals(dismissalStream, errors: dismissalErrors)
    }
  }

  deinit {
    // Safety net for tear-down paths that miss `cleanupSync`. Swift 6 makes
    // `deinit` nonisolated; reading `@MainActor`-isolated state requires
    // `MainActor.assumeIsolated`. This is valid only because the store is
    // owned by `@MainActor` code (`ProfileSession`), so the isolation
    // assumption holds in practice. If ownership ever moves off `@MainActor`,
    // convert this to a separate `cancel()` method invoked from a main-actor
    // context instead. Cancels both strongly-held observation Tasks so they
    // do not retain `self` (and their streams' GRDB connections) forever.
    MainActor.assumeIsolated {
      instrumentChangeObservationTask?.cancel()
      dismissalObservationTask?.cancel()
      for task in narrationTasks.values { task.cancel() }
      narrationTasks.removeAll()
    }
  }

  /// Tears down the observation tasks and any in-flight narration tasks.
  /// Idempotent. Called from `ProfileSession.cleanupSync(coordinator:)`.
  func stopObserving() {
    instrumentChangeObservationTask?.cancel()
    dismissalObservationTask?.cancel()
    for task in narrationTasks.values { task.cancel() }
    narrationTasks.removeAll()
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
  /// the rest of the session. The optimistic mutation (hide the card, bump the
  /// fatigue tally, re-rank) is applied synchronously before the first `await`
  /// so the UI updates instantly, then the per-kind count is written through to
  /// the repository.
  ///
  /// The card stays hidden only if the persist succeeds: on failure the prior
  /// `dismissedIds` / `dismissals[kind]` are restored and the list re-ranked,
  /// re-showing the card. Rollback is required because `applyPersistedDismissals`
  /// max-merges the per-kind count, so an un-reverted optimistic bump could
  /// never be corrected by a later (lower) DB echo.
  func dismiss(_ insight: ScoredInsight) async {
    let kind = insight.insight.kind
    let priorDismissedIds = dismissedIds
    let priorCount = dismissals[kind]

    dismissedIds.insert(insight.id)
    dismissals[kind, default: 0] += 1
    rerank()

    do {
      // The atomic increment in the repository is the source of truth; the
      // observation stream echoes the committed count back, reconciling the
      // optimistic bump above (idempotent — same value).
      _ = try await dismissalRepository.recordDismissal(of: kind)
    } catch {
      // Roll back the optimistic mutation so the in-memory tally cannot drift
      // above the committed count (the max-merge in the observation apply would
      // otherwise pin the overstated value until a successful write or relaunch).
      dismissedIds = priorDismissedIds
      dismissals[kind] = priorCount
      rerank()
      logger.error("Failed to persist insight dismissal: \(error)")
      self.error = error
    }
  }

  /// Re-ranks the cached input in place (no off-main rebuild) so the published
  /// list reflects the current `dismissals` fatigue table and `dismissedIds`.
  /// Falls back to filtering the current list when no input is cached.
  private func rerank() {
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

  /// Reconciles the in-memory fatigue table from an authoritative DB emission
  /// and re-ranks the cached input in place (no off-main rebuild).
  ///
  /// Per-kind `max`-merge rather than a wholesale replace: a `dismiss(_:)`
  /// bumps `dismissals` optimistically and write-throughs asynchronously, so
  /// two dismisses of the same kind can race ahead of the first committed
  /// echo. Taking the max means an in-flight optimistic bump is never
  /// overwritten by a stale (lower) DB echo. Membership is still DB-authoritative:
  /// kinds absent from the emission are dropped, so a remote zone wipe /
  /// `deleteAll` clears the table.
  ///
  /// internal (not `private`) so the `+Observation` extension's stream-
  /// draining child task can call it across files.
  func applyPersistedDismissals(_ tallies: [InsightDismissal]) {
    let dbKinds = Set(tallies.map(\.kind))
    for tally in tallies {
      dismissals[tally.kind] = max(dismissals[tally.kind, default: 0], tally.count)
    }
    dismissals = dismissals.filter { dbKinds.contains($0.key) }
    rerank()
  }

  /// Logs and surfaces an error from the dismissal observation stream.
  /// internal (not `private`) so the `+Observation` extension can call it.
  func surface(error: any Error) {
    logger.error("Insight dismissal observation error: \(error)")
    self.error = error
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

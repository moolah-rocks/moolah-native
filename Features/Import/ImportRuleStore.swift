import Foundation
import OSLog
import Observation

/// Thin wrapper around `ImportRuleRepository`. Exposes an ordered `rules`
/// list for the rules settings view and a helper that counts how many
/// already-imported transactions would match a candidate rule (live preview).
///
/// Reactive: subscribes to `repository.observeAll()` from `init`, so any
/// GRDB write — local OR sync-driven — propagates to `rules` without a
/// manual reload. Mutations (`create` / `update` / `delete` / `reorder`)
/// are pass-throughs; the reactive observation delivers the post-write
/// state.
@Observable
@MainActor
final class ImportRuleStore {

  private(set) var rules: [ImportRule] = []
  private(set) var error: Error?
  /// Per-rule historical match summary, keyed by rule id. Populated by
  /// `refreshStats(backend:)` — computed at load time rather than stored
  /// on `ImportRule` so the count tracks whatever the current rule
  /// conditions match. Values default to `(0, nil)` for rules whose
  /// conditions no transactions match.
  private(set) var matchStats: [UUID: RuleMatchStats] = [:]

  struct RuleMatchStats: Sendable, Equatable {
    var matchCount: Int
    var lastMatchedAt: Date?
  }

  private let repository: any ImportRuleRepository
  private let logger = Logger(subsystem: "com.moolah.app", category: "ImportRuleStore")

  /// The single observation `Task` that runs the `withTaskGroup` of
  /// child tasks subscribing to `repository.observeAll()` and
  /// `repository.observeErrors()`. Spawned from `init`, torn down by
  /// `stopObserving()` (called from `ProfileSession.cleanupSync`) or by
  /// `deinit` as a safety net. Import rules carry no converted balances,
  /// so the group only has the two repository streams — there is no
  /// conversion-service subscription as in `AccountStore` /
  /// `EarmarkStore`.
  private var observationTask: Task<Void, Never>?

  /// The shared instrument-registry change seam + the child task draining it.
  /// An in-app profile import writes `import_rule` rows through its own
  /// `DatabaseQueue`, which the open session's `observeAll()` never sees;
  /// re-fetching on each registry tick live-refreshes the open list across the
  /// DB boundary — same backstop as `AccountGroupStore` (#1149). Nil in
  /// previews / legacy tests.
  private let instrumentChanges: (any InstrumentChangeObserving)?
  private var instrumentChangeObservationTask: Task<Void, Never>?

  /// Monotonic counter over authoritative `observeAll()` snapshots. The
  /// instrument-registry refresh path captures it before its `fetchAll()`
  /// and drops a stale refetch that raced a fresher snapshot — see
  /// `applyInstrumentRegistryRefresh`. `private(set)` (only
  /// `bumpSnapshotGeneration()` writes it) + `@ObservationIgnored` (a pure
  /// guard counter no view reads). Mirrors `AccountGroupStore`.
  @ObservationIgnored private(set) var snapshotGeneration: UInt64 = 0

  /// The single increment path for `snapshotGeneration`.
  private func bumpSnapshotGeneration() {
    snapshotGeneration &+= 1
  }

  /// Test-only emission tick stream. Yields `()` after every state
  /// assignment in `apply(rules:)`. Tests use the
  /// `TestableStoreObservation` helpers in
  /// `MoolahTests/Support/TestableStoreObservation.swift` to await
  /// emissions deterministically. `internal` access is intentional;
  /// `@testable import Moolah` exposes it to the test target.
  let testObservationTickStream: AsyncStream<Void>
  private let testObservationTickContinuation: AsyncStream<Void>.Continuation

  init(
    repository: any ImportRuleRepository,
    instrumentChanges: (any InstrumentChangeObserving)? = nil
  ) {
    self.repository = repository
    self.instrumentChanges = instrumentChanges
    let pair = AsyncStream<Void>.makeStream()
    self.testObservationTickStream = pair.stream
    self.testObservationTickContinuation = pair.continuation

    // Strong `self` capture is intentional: the store is `@MainActor`,
    // the task already holds an implicit strong reference, and
    // `stopObserving()` (called from `cleanupSync`) is the sole lifetime
    // gate. A weak capture would just add a nil-check hazard without
    // preventing the retain — and `guard let self else { return }` would
    // mask cancellation-propagation bugs by silently exiting.
    observationTask = Task { await self.observe() }
    if let instrumentChanges {
      let changes = instrumentChanges.observeChanges()
      instrumentChangeObservationTask = Task { [self] in
        await self.observeInstrumentRegistryChanges(changes)
      }
    }
  }

  deinit {
    // Safety net for the case where `cleanupSync` is missed (e.g. an
    // early-error tear-down path that drops the ProfileSession without
    // calling cleanupSync). Cancels the strongly-held observation Task
    // so it does not retain `self` and a stale GRDB connection forever.
    // Under normal lifecycle, `stopObserving()` runs first via
    // `cleanupSync` and this is a no-op. Swift 6 makes `deinit`
    // nonisolated; reading `@MainActor`-isolated state requires
    // `MainActor.assumeIsolated`. The store is owned by main-actor
    // code (`ProfileSession`), so the assumption holds in practice.
    MainActor.assumeIsolated {
      observationTask?.cancel()
      instrumentChangeObservationTask?.cancel()
      testObservationTickContinuation.finish()
    }
  }

  // MARK: - Observation

  /// Subscribes to the two reactive streams in parallel via a
  /// `TaskGroup`. The child tasks run nonisolated; each per-emission
  /// body awaits a `@MainActor`-isolated method on `self` so state
  /// assignments happen on the main actor. Capturing the streams
  /// locally (instead of `self.repository.observeAll()` inside the
  /// `addTask` closure) lets the region-based isolation checker reason
  /// about Sendable-ness.
  private func observe() async {
    let rulesStream = repository.observeAll()
    let ruleErrors = repository.observeErrors()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { [self] in
        for await fresh in rulesStream {
          await self.applyRulesSnapshot(fresh)
        }
      }
      group.addTask { [self] in
        for await error in ruleErrors {
          await self.surface(error: error)
        }
      }
      // Cancellation of `observationTask` cancels the group; the
      // `for await` loops exit; the group returns naturally.
    }
  }

  /// The **authoritative** per-emission entry point for the `observeAll()`
  /// subscription. Bumps `snapshotGeneration` so a concurrent
  /// instrument-registry refetch can detect that it raced a fresher snapshot,
  /// then applies it. Mirrors `AccountGroupStore.applyGroupsSnapshot`.
  private func applyRulesSnapshot(_ fresh: [ImportRule]) async {
    bumpSnapshotGeneration()
    await apply(rules: fresh)
  }

  /// Applies a fresh rules snapshot. Wrapped in the reactive-store signpost
  /// interval so benchmarks and Instruments traces can attribute `mainThreadMs`
  /// to this method. The repo orders by `position`; we re-sort defensively in
  /// case a future change in the observation projection drops that guarantee.
  /// Does NOT bump the generation — only authoritative `observeAll()` snapshots
  /// do, so the registry-refresh guard stays meaningful.
  private func apply(rules fresh: [ImportRule]) async {
    await withReactiveStoreSignpost("import-rule-store-apply") {
      self.rules = fresh.sorted { $0.position < $1.position }
      testObservationTickContinuation.yield(())
    }
  }

  /// Consumes the shared instrument registry's change stream. Each tick
  /// re-fetches the rules so a write that landed through a connection
  /// `observeAll()` doesn't track (an in-app import's own `DatabaseQueue`)
  /// still reaches the open list. Re-checks `Task.isCancelled` after each
  /// suspension, and captures `snapshotGeneration` *before* the `fetchAll()`
  /// so a stale refetch can be dropped. Mirrors `AccountGroupStore`.
  private func observeInstrumentRegistryChanges(_ changes: AsyncStream<Void>) async {
    for await _ in changes {
      guard !Task.isCancelled else { return }
      let observedGeneration = snapshotGeneration
      do {
        let fresh = try await repository.fetchAll()
        guard !Task.isCancelled else { return }
        await applyInstrumentRegistryRefresh(fresh, observedGeneration: observedGeneration)
      } catch {
        surface(error: error)
      }
    }
  }

  /// Applies an instrument-registry-triggered refetch, but only if no
  /// authoritative `observeAll()` snapshot has landed since the fetch was
  /// issued. The `fetchAll()` runs unordered with respect to `observeAll()`; a
  /// fetch that read the database before a concurrent write committed returns a
  /// stale row set, and applying it after a fresher snapshot would clobber
  /// `rules` back to the pre-write state (#1209). The generation check and the
  /// assignment run with no intervening suspension on the main actor. Internal
  /// so the store's refresh tests can drive the guard path directly.
  func applyInstrumentRegistryRefresh(
    _ fresh: [ImportRule], observedGeneration: UInt64
  ) async {
    guard snapshotGeneration == observedGeneration else { return }
    await apply(rules: fresh)
  }

  private func surface(error: any Error) {
    logger.error("ImportRuleStore observation error: \(error.localizedDescription)")
    self.error = error
  }

  /// Tears down the observation task. Idempotent. Called from
  /// `ProfileSession.cleanupSync(coordinator:)` AFTER any
  /// `deleteAllLocalData()` call so the empty-state transition is
  /// emitted to subscribed views before cancellation.
  ///
  /// Returns the moment `Task.cancel()` is issued — the underlying
  /// `for await` loops only notice cancellation on the next stream
  /// check. Tests asserting "no emission after stop" must call
  /// `awaitObservationTermination()` before the assertion.
  func stopObserving() {
    observationTask?.cancel()
    instrumentChangeObservationTask?.cancel()
  }

  /// Test-only. Awaits the observation tasks to fully terminate after
  /// `stopObserving()`, then nils the references.
  func awaitObservationTermination() async {
    await observationTask?.value
    observationTask = nil
    await instrumentChangeObservationTask?.value
    instrumentChangeObservationTask = nil
  }

  // MARK: - Mutations
  //
  // Mutations are pass-through under the reactive design: every method
  // calls the repository, the GRDB write commits, and
  // `repository.observeAll()` delivers the authoritative state via the
  // observation task spawned in `init`. There is no optimistic insert /
  // rollback path — the reactive emission IS the state update.
  //
  // Return shapes (`ImportRule?` for create/update) are preserved from
  // the pre-reactive store so existing call sites compile unchanged.

  /// Pass-through create. The reactive observation delivers the new rule
  /// via `observeAll()` shortly after the GRDB write commits.
  @discardableResult
  func create(_ rule: ImportRule) async -> ImportRule? {
    error = nil
    do {
      let saved = try await repository.create(rule)
      logger.debug("Created rule: \(saved.name)")
      return saved
    } catch {
      self.error = error
      logger.error("Create rule failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  /// Pass-through update. See `create(_:)` for the rationale; the
  /// reactive observation delivers the updated rule.
  @discardableResult
  func update(_ rule: ImportRule) async -> ImportRule? {
    error = nil
    do {
      let saved = try await repository.update(rule)
      logger.debug("Updated rule: \(saved.name)")
      return saved
    } catch {
      self.error = error
      logger.error("Update rule failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  /// Pass-through delete. The observation emits the post-delete list.
  func delete(id: UUID) async {
    error = nil
    do {
      try await repository.delete(id: id)
      logger.debug("Deleted rule \(id)")
    } catch {
      self.error = error
      logger.error("Delete rule failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Pass-through reorder. The repository atomically renumbers
  /// `position` across every rule inside a single GRDB transaction;
  /// the observation then re-emits the table in the new order.
  func reorder(_ orderedIds: [UUID]) async {
    error = nil
    do {
      try await repository.reorder(orderedIds)
    } catch {
      self.error = error
      logger.error("Reorder rules failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Populate `matchStats` for every rule by running it against existing
  /// imported transactions. Called after the rules screen appears and
  /// after each rule-mutation method so the "matched N times · last
  /// matched X" caption stays fresh. Uses one transaction fetch shared
  /// across every rule — O(rules × transactions) in memory but only one
  /// network call.
  func refreshStats(backend: any BackendProvider) async {
    do {
      let page = try await backend.transactions.fetch(
        filter: TransactionFilter(), page: 0, pageSize: 2000)
      var stats: [UUID: RuleMatchStats] = [:]
      for rule in rules {
        var count = 0
        var lastMatchedAt: Date?
        for transaction in page.transactions {
          guard let origin = transaction.importOrigin?.singleOrigin,
            let routingAccount = transaction.legs.first?.accountId
          else { continue }
          let parsed = ParsedTransaction(
            date: transaction.date,
            legs: transaction.legs.map {
              ParsedLeg(
                accountId: $0.accountId,
                instrument: $0.instrument,
                quantity: $0.quantity,
                type: $0.type)
            },
            rawRow: [],
            rawDescription: origin.rawDescription,
            rawAmount: origin.rawAmount,
            rawBalance: origin.rawBalance,
            bankReference: origin.bankReference)
          let eval = ImportRulesEngine.evaluate(
            parsed, routedAccountId: routingAccount, rules: [rule])
          if !eval.matchedRuleIds.isEmpty {
            count += 1
            if lastMatchedAt == nil || origin.importedAt > (lastMatchedAt ?? .distantPast) {
              lastMatchedAt = origin.importedAt
            }
          }
        }
        stats[rule.id] = RuleMatchStats(matchCount: count, lastMatchedAt: lastMatchedAt)
      }
      matchStats = stats
    } catch {
      logger.error(
        "refreshStats failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Live preview: given a candidate set of conditions + match mode, count
  /// how many already-imported transactions would match. The rule-editor
  /// view debounces before calling so we don't hammer the backend on every
  /// keystroke.
  func countAffected(
    conditions: [RuleCondition],
    matchMode: MatchMode,
    accountScope: UUID?,
    backend: any BackendProvider
  ) async -> Int {
    do {
      let page = try await backend.transactions.fetch(
        filter: TransactionFilter(), page: 0, pageSize: 2000)
      let candidate = ImportRule(
        name: "preview",
        position: 0,
        matchMode: matchMode,
        conditions: conditions,
        actions: [],
        accountScope: accountScope)
      return page.transactions.reduce(0) { count, transaction in
        guard let origin = transaction.importOrigin?.singleOrigin,
          let routingAccount = transaction.legs.first?.accountId
        else {
          return count
        }
        let parsed = ParsedTransaction(
          date: transaction.date,
          legs: transaction.legs.map {
            ParsedLeg(
              accountId: $0.accountId,
              instrument: $0.instrument,
              quantity: $0.quantity,
              type: $0.type)
          },
          rawRow: [],
          rawDescription: origin.rawDescription,
          rawAmount: origin.rawAmount,
          rawBalance: origin.rawBalance,
          bankReference: origin.bankReference)
        let eval = ImportRulesEngine.evaluate(
          parsed, routedAccountId: routingAccount, rules: [candidate])
        return count + (eval.matchedRuleIds.isEmpty ? 0 : 1)
      }
    } catch {
      logger.error(
        "countAffected failed: \(error.localizedDescription, privacy: .public)")
      return 0
    }
  }
}

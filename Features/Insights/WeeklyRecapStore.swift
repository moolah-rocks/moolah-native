import Foundation
import OSLog
import Observation

/// Manages the opt-in once-per-ISO-week recap card shown at the top of the
/// Analysis surface (issue #1042).
///
/// ## Opt-in injection
/// The recap opt-in preference is read through the injected `isOptedIn`
/// closure rather than directly from `UserDefaults.moolahShared` or
/// `@AppStorage`. This keeps tests free of shared-defaults mutations:
/// callers pass `{ UserDefaults.moolahShared.bool(forKey: .weeklyRecapEnabledKey) }`
/// in production, and a fixed closure (`{ true }` / `{ false }`) in tests.
///
/// ## Date injection
/// `now` is a `@Sendable () -> Date` closure (default `Date.init`). Pure
/// logic (`WeeklyRecapWindow.shouldShow`) only ever sees the value returned by
/// `now()` — never a bare `Date()` inside the store.
@Observable
@MainActor
final class WeeklyRecapStore {

  // MARK: - Published state

  private(set) var recap: RecapState = .hidden

  // MARK: - Dependencies

  private let insightStore: InsightStore
  private let narrator: any InsightNarrating
  private let availability: any ModelAvailabilityProviding
  private let lastShownStore: any RecapLastShownStoring
  /// Stable identity captured at init time for `lastShownStore` keying.
  private let profileId: UUID
  /// Returns whether the user has opted into the weekly recap. Injected so
  /// tests can supply a fixed value without touching shared `UserDefaults`.
  private let isOptedIn: @Sendable () -> Bool
  /// Returns the current date. Injected so pure logic never calls `Date()`
  /// internally and tests can pin time deterministically.
  private let now: @Sendable () -> Date

  private let logger = Logger(subsystem: "com.moolah.app", category: "WeeklyRecapStore")

  /// Re-entrancy guard: prevents overlapping `prepareIfDue()` invocations from
  /// racing against each other (e.g. from both the priming `.task` and a
  /// scene-active `.onChange` firing in quick succession).
  private var isPreparing = false

  // MARK: - Init

  init(
    insightStore: InsightStore,
    narrator: any InsightNarrating,
    availability: any ModelAvailabilityProviding,
    lastShownStore: any RecapLastShownStoring,
    profileId: UUID,
    isOptedIn: @escaping @Sendable () -> Bool = {
      UserDefaults.moolahShared.bool(forKey: UserDefaults.weeklyRecapEnabledKey)
    },
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.insightStore = insightStore
    self.narrator = narrator
    self.availability = availability
    self.lastShownStore = lastShownStore
    self.profileId = profileId
    self.isOptedIn = isOptedIn
    self.now = now
  }

  // MARK: - API

  /// Shows the recap card for this ISO week if all preconditions are met.
  ///
  /// Returns early (leaving `recap = .hidden`) unless:
  /// 1. The user has opted in (`isOptedIn()` is true).
  /// 2. The model is usable (`availability.current().isUsable`).
  /// 3. The recap hasn't been shown in the current ISO week
  ///    (`WeeklyRecapWindow.shouldShow`).
  /// 4. There is at least one insight to narrate.
  ///
  /// When all preconditions pass, records the current week as shown
  /// immediately (before awaiting narration) so a concurrent re-entry or
  /// a crash during generation does not re-show the card. Sets
  /// `.preparing`, narrates the top ≤5 insights, then transitions to
  /// `.ready`. On any narrator error, falls back to `TemplateNarrator`.
  ///
  /// A second concurrent call while one is already in flight returns
  /// immediately without modifying `recap` (re-entrancy guard).
  func prepareIfDue() async {
    guard !isPreparing else { return }

    let currentNow = now()

    guard isOptedIn() else {
      recap = .hidden
      return
    }

    guard availability.current().isUsable else {
      recap = .hidden
      return
    }

    var isoCalendar = Calendar(identifier: .iso8601)
    isoCalendar.timeZone = TimeZone(abbreviation: "UTC") ?? .current

    guard
      WeeklyRecapWindow.shouldShow(
        now: currentNow,
        lastShown: lastShownStore.lastShown(forProfile: profileId),
        calendar: isoCalendar)
    else {
      recap = .hidden
      return
    }

    let topInsights = Array(insightStore.insights.prefix(5))
    guard !topInsights.isEmpty else {
      recap = .hidden
      return
    }

    // Record first, before awaiting narration, so a crash or concurrent
    // re-entry in the same week doesn't re-show the card.
    lastShownStore.setLastShown(currentNow, forProfile: profileId)

    isPreparing = true
    defer { isPreparing = false }

    recap = .preparing

    let items = topInsights.map { scored in
      NarrationRequest.Item(
        title: scored.insight.title,
        detail: scored.insight.detail,
        facts: scored.insight.facts)
    }
    let request = NarrationRequest.weeklyRecap(items: items)

    let text = await consumeNarration(request: request)

    guard !Task.isCancelled else { return }
    recap = .ready(text)
  }

  /// Hides the recap card. Does **not** un-record the shown week — the card
  /// stays gone until the next ISO week, matching the intended UX
  /// ("once per week, dismiss-to-hide" not "dismiss-to-never-show").
  func dismiss() {
    recap = .hidden
  }

  // MARK: - Private

  /// Consumes the narrator's stream, collecting the final snapshot. On any
  /// error (including `NarrationError.fellBack`) falls back to
  /// `TemplateNarrator` so the card always shows something useful.
  private func consumeNarration(request: NarrationRequest) async -> String {
    var latest = ""
    do {
      for try await snapshot in narrator.narrate(request) {
        guard !Task.isCancelled else { return latest }
        latest = snapshot
      }
      return latest
    } catch {
      logger.error("WeeklyRecap narration failed: \(error)")
      return await templateFallback(for: request)
    }
  }

  /// Produces the `TemplateNarrator`'s deterministic output. Never throws.
  private func templateFallback(for request: NarrationRequest) async -> String {
    var result = ""
    do {
      for try await snapshot in TemplateNarrator().narrate(request) {
        result = snapshot
      }
    } catch {
      // TemplateNarrator never throws; belt-and-suspenders.
      logger.error("WeeklyRecap template fallback unexpectedly threw: \(error)")
    }
    return result
  }
}

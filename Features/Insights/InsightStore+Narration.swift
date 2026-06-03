import Foundation
import OSLog

/// File-private logger for the `nonisolated static` narration helper, which
/// can't read the store's instance `logger`. Matches `InsightStore.logger`'s
/// subsystem/category so narration diagnostics land alongside the rest of the
/// store's logs.
private let narratorLogger = Logger(subsystem: "com.moolah.app", category: "InsightStore")

// MARK: - Batch headline generation

extension InsightStore {
  /// Resolves the display headline for every member of `ranked`'s visible
  /// batch concurrently, then — once the *whole* batch is ready — publishes it
  /// as `items` on the main actor. Holds publication until the last headline
  /// resolves so the surface never shows a half-narrated batch.
  ///
  /// ## Supersession
  /// Bumps `generation` and captures the token before resolving. After all
  /// headlines resolve it re-reads `generation`: if a newer `refresh()` has run
  /// in the meantime the token no longer matches, so this run returns without
  /// publishing — the newer run owns `items`. This is the cancellation seam (no
  /// per-request `Task` to cancel; the narrator's own work runs inside its
  /// stream and the stale result is simply discarded).
  ///
  /// ## Concurrency
  /// The store is `@MainActor`. Cache reads/writes, the availability check, and
  /// the final `items` publish all happen here on the main actor — never inside
  /// a child task. The fan-out task group's children capture only `Sendable`
  /// values (the `Sendable` narrator and the `Sendable` insights), consume the
  /// narrator's stream off-main (per `InsightNarrating`), and return
  /// `(id, headline)`; there is no `@MainActor` state in the children and so no
  /// data race. Cache-hit insights skip the group entirely.
  func publishBatch(_ ranked: [ScoredInsight]) async {
    let batch = Array(ranked.prefix(maxVisible))
    generation += 1
    let token = generation

    // Resolve on the main actor: split into already-cached vs. needs-generation.
    // The narrator is consulted only when the model is usable; otherwise every
    // headline is the detector title.
    var resolved: [String: String] = [:]
    var toGenerate: [ScoredInsight] = []
    let canNarrate = currentAvailability.isUsable
    for scored in batch {
      if let cached = headlineCache[scored.id] {
        resolved[scored.id] = cached
      } else if canNarrate {
        toGenerate.append(scored)
      } else {
        resolved[scored.id] = scored.insight.title
      }
    }

    // Carries the title for each insight whose narration fell back, so the
    // batch still publishes with the title but the cache is NOT written (a
    // transient failure must not suppress narration for the rest of the
    // session — the next `refresh()` retries generation).
    var fellBackTitles: [String: String] = [:]
    if !toGenerate.isEmpty {
      let narrator = self.narrator
      let generated = await withTaskGroup(of: (String, String?).self) { group in
        for scored in toGenerate {
          group.addTask {
            (scored.id, await Self.narratedHeadline(for: scored, narrator: narrator))
          }
        }
        var map: [String: String?] = [:]
        for await pair in group {
          map[pair.0] = pair.1
        }
        return map
      }
      // Back on the main actor: cache only genuine narrations; for fallbacks,
      // use the title for display but don't cache it so a retry is possible.
      for scored in toGenerate {
        if let headline = generated[scored.id] ?? nil {
          headlineCache[scored.id] = headline
          resolved[scored.id] = headline
        } else {
          fellBackTitles[scored.id] = scored.insight.title
        }
      }
    }

    // A newer refresh superseded this batch — discard, the newer run publishes.
    guard token == generation else { return }
    // Hold-until-ready: the whole batch publishes together, using the resolved
    // headline, then the (uncached) fallback title, then the title as a guard.
    items = batch.map { scored in
      let headline = resolved[scored.id] ?? fellBackTitles[scored.id] ?? scored.insight.title
      return ForYouItem(scored: scored, headline: headline)
    }
  }

  /// Drives the narrator stream to completion and returns its final snapshot,
  /// or `nil` if the stream throws (model error / provenance guard rejection)
  /// — the caller falls the display back to the detector `title` without
  /// caching, so a transient failure does not permanently suppress narration.
  /// `nonisolated static` so the fan-out task group's children can call it off
  /// the main actor capturing only `Sendable` values.
  nonisolated private static func narratedHeadline(
    for scored: ScoredInsight,
    narrator: any InsightNarrating
  ) async -> String? {
    let insight = scored.insight
    let request = NarrationRequest.singleInsight(title: insight.title, facts: insight.facts)
    var latest = insight.title
    do {
      for try await snapshot in narrator.narrate(request) {
        latest = snapshot
      }
      return latest
    } catch {
      narratorLogger.error(
        "Narration failed for insight \(insight.id, privacy: .public); falling back to title: \(error)"
      )
      return nil
    }
  }
}

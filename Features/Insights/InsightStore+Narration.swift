import Foundation

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

    if !toGenerate.isEmpty {
      let narrator = self.narrator
      let generated = await withTaskGroup(of: (String, String).self) { group in
        for scored in toGenerate {
          group.addTask {
            (scored.id, await Self.narratedHeadline(for: scored, narrator: narrator))
          }
        }
        var map: [String: String] = [:]
        for await pair in group {
          map[pair.0] = pair.1
        }
        return map
      }
      // Back on the main actor: fold the generated headlines into the cache and
      // the result set.
      for (id, headline) in generated {
        headlineCache[id] = headline
        resolved[id] = headline
      }
    }

    // A newer refresh superseded this batch — discard, the newer run publishes.
    guard token == generation else { return }
    items = batch.map { ForYouItem(scored: $0, headline: resolved[$0.id] ?? $0.insight.title) }
  }

  /// Drives the narrator stream to completion and returns its final snapshot,
  /// or the detector `title` if the stream throws (model error / provenance
  /// guard rejection). `nonisolated static` so the fan-out task group's
  /// children can call it off the main actor capturing only `Sendable` values.
  nonisolated private static func narratedHeadline(
    for scored: ScoredInsight,
    narrator: any InsightNarrating
  ) async -> String {
    let insight = scored.insight
    let request = NarrationRequest.singleInsight(title: insight.title, facts: insight.facts)
    var latest = insight.title
    do {
      for try await snapshot in narrator.narrate(request) {
        latest = snapshot
      }
      return latest
    } catch {
      return insight.title
    }
  }
}

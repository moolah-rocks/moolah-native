import Foundation

// MARK: - Narration

extension InsightStore {
  /// Lazily narrates the given insight into prose. If the model is not usable,
  /// or if narration for this insight is already in progress or cached, this
  /// is a no-op. Immediately sets `.streaming("")` and spawns a background task;
  /// the view observes `narration[id]` for progressive updates. On completion
  /// stores `.done`; on any error (including `NarrationError.fellBack`) falls
  /// back to the template narrator and stores `.fellBackToTemplate` (issue #1042).
  func narrate(_ scored: ScoredInsight) {
    let id = scored.id
    guard currentAvailability.isUsable else { return }
    // Cache hit: streaming, done, or template fallback already exist.
    switch narration[id] {
    case .streaming, .done, .fellBackToTemplate:
      return
    case .idle, nil:
      break
    }

    let insight = scored.insight
    let request = NarrationRequest.singleInsight(
      title: insight.title,
      facts: insight.facts)

    narration[id] = .streaming("")

    let task = Task { [self] in
      await consumeNarration(id: id, request: request)
    }
    narrationTasks[id] = task
  }

  /// Cancels any in-flight narration task for `id` and resets its state to
  /// `.idle`. No-op when no task is in flight — does not wipe a cached
  /// `.done` or `.fellBackToTemplate` result.
  func cancelNarration(_ id: String) {
    guard narrationTasks[id] != nil else { return }
    narrationTasks[id]?.cancel()
    narrationTasks.removeValue(forKey: id)
    narration[id] = .idle
  }

  /// Consumes the narrator's stream, updating `narration[id]` on each snapshot.
  /// On clean completion stores `.done`; on any error computes the template
  /// fallback and stores `.fellBackToTemplate`.
  private func consumeNarration(id: String, request: NarrationRequest) async {
    defer { narrationTasks.removeValue(forKey: id) }
    var latestSnapshot = ""
    do {
      for try await snapshot in narrator.narrate(request) {
        guard !Task.isCancelled else {
          narration[id] = .idle
          return
        }
        latestSnapshot = snapshot
        narration[id] = .streaming(snapshot)
      }
      guard !Task.isCancelled else {
        narration[id] = .idle
        return
      }
      narration[id] = .done(latestSnapshot)
    } catch {
      guard !Task.isCancelled else {
        narration[id] = .idle
        return
      }
      // Log the original error before falling back so diagnostics are preserved.
      logger.error("Narration failed for insight \(id): \(error)")
      // Any error (including NarrationError.fellBack) triggers the deterministic
      // template fallback so the user always sees something useful.
      let fallback = await templateFallback(for: request)
      narration[id] = .fellBackToTemplate(fallback)
    }
  }

  /// Produces the template narrator's output for `request` by consuming its
  /// stream. `TemplateNarrator` emits exactly one snapshot and finishes
  /// immediately; this helper collects it. Errors are ignored — the template
  /// is deterministic and does not throw.
  private func templateFallback(for request: NarrationRequest) async -> String {
    var result = ""
    do {
      for try await snapshot in TemplateNarrator().narrate(request) {
        result = snapshot
      }
    } catch {
      // TemplateNarrator never throws; guard belt-and-suspenders.
    }
    return result
  }
}

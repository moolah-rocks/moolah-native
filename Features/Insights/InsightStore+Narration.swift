import Foundation

// MARK: - Narration

extension InsightStore {
  /// Lazily narrates the given insight into prose. If the model is not usable,
  /// or if narration for this insight is already in progress or cached, this
  /// is a no-op. Streams partial output through `narration[id]` so the view
  /// can render progressive text; on completion, stores `.done`. On any error
  /// (including `NarrationError.fellBack`) falls back to the template narrator
  /// and stores `.fellBackToTemplate` (issue #1042).
  func narrate(_ scored: ScoredInsight) async {
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
      detail: insight.detail,
      facts: insight.facts)

    narration[id] = .streaming("")

    let task = Task { [weak self] in
      guard let self else { return }
      await consumeNarration(id: id, request: request)
    }
    narrationTasks[id] = task
    await task.value
  }

  /// Cancels any in-flight narration task for `id` and resets its state to
  /// `.idle`. Idempotent — safe to call when no task is running.
  func cancelNarration(_ id: String) {
    narrationTasks[id]?.cancel()
    narrationTasks.removeValue(forKey: id)
    narration[id] = .idle
  }

  /// Consumes the narrator's stream, updating `narration[id]` on each snapshot.
  /// On clean completion stores `.done`; on any error computes the template
  /// fallback and stores `.fellBackToTemplate`.
  private func consumeNarration(id: String, request: NarrationRequest) async {
    var latestSnapshot = ""
    do {
      for try await snapshot in narrator.narrate(request) {
        guard !Task.isCancelled else { return }
        latestSnapshot = snapshot
        narration[id] = .streaming(snapshot)
      }
      guard !Task.isCancelled else { return }
      narration[id] = .done(latestSnapshot)
    } catch {
      guard !Task.isCancelled else { return }
      // Any error (including NarrationError.fellBack) triggers the deterministic
      // template fallback so the user always sees something useful.
      let fallback = await templateFallback(for: request)
      narration[id] = .fellBackToTemplate(fallback)
    }
    narrationTasks.removeValue(forKey: id)
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

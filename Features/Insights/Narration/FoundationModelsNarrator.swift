import FoundationModels
import os

private let logger = Logger(subsystem: "com.moolah.app", category: "Narration")

/// Narrates insights using the on-device Foundation Models language model.
/// Streams cumulative snapshots so the caller can display partial output while
/// generation is in progress. On completion, runs `NumericProvenanceGuard` to
/// verify every number in the generated text was supplied verbatim in the
/// request's facts — if any number fails provenance, or if generation throws,
/// the stream finishes with `NarrationError.fellBack` so the caller can
/// substitute the deterministic template output (issue #1042).
///
/// Session API shape:
/// - `LanguageModelSession(instructions:)` — per-request session with a system prompt.
/// - `session.streamResponse(to: String, options: GenerationOptions)` — returns
///   `ResponseStream<String>`, an `AsyncSequence` of `Snapshot` values where
///   `snapshot.content` is a cumulative `String` (the entire response so far).
/// - `GenerationOptions(sampling: .greedy)` — deterministic token selection.
struct FoundationModelsNarrator {
  /// Generation options passed to every `streamResponse` call.
  /// Greedy sampling produces the most deterministic output across runs,
  /// reducing the chance of the provenance guard flipping between calls.
  let options: GenerationOptions

  init(options: GenerationOptions = .init(sampling: .greedy)) {
    self.options = options
  }
}

extension FoundationModelsNarrator: InsightNarrating {
  nonisolated func narrate(_ request: NarrationRequest) -> AsyncThrowingStream<String, any Error> {
    let built = NarrationPromptBuilder.build(request)
    let allFacts = request.allFacts
    let groundingTitle = request.groundingTitle
    let generationOptions = options

    return AsyncThrowingStream { continuation in
      // Shed to a task with elevated priority; `narrate` is `nonisolated` so
      // the task runs on the global executor, not the main actor.
      let task = Task(priority: .userInitiated) {
        do {
          // Create a per-request session. Sessions are not shared across
          // requests; each call gets a fresh context window, which also
          // bounds context-window-exceeded errors.
          let session = LanguageModelSession(instructions: built.instructions)
          var latestSnapshot = ""

          for try await snapshot in session.streamResponse(
            to: built.prompt, options: generationOptions)
          {
            if Task.isCancelled { break }
            latestSnapshot = snapshot.content
            continuation.yield(latestSnapshot)
          }

          guard !Task.isCancelled else {
            continuation.finish(throwing: CancellationError())
            return
          }

          // Verify that every number in the completed narration can be
          // traced back to a fact supplied by the caller.
          guard
            NumericProvenanceGuard.isGrounded(
              latestSnapshot, title: groundingTitle, facts: allFacts)
          else {
            continuation.finish(throwing: NarrationError.fellBack)
            return
          }

          continuation.finish()
        } catch {
          // Log the original error before mapping to the fallback signal
          // so diagnostics are preserved for debugging.
          logger.error("FoundationModelsNarrator: generation failed — \(error)")
          continuation.finish(throwing: NarrationError.fellBack)
        }
      }

      // Cancel the generation task when the stream is abandoned (e.g. the
      // user navigates away before narration completes).
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

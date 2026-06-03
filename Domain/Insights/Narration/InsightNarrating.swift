import Foundation

/// Errors a narrator may throw into its output stream. Callers that receive
/// `.fellBack` should substitute the template narrator's output — the user
/// sees the deterministic fallback, not the error (issue #1042).
enum NarrationError: Error {
  /// The narrator could not produce grounded output (provenance check failed
  /// or the model threw) — the caller must fall back to the template.
  case fellBack
}

/// Produces narration for a `NarrationRequest` as a stream of cumulative
/// snapshots. The final element is the complete narration text.
///
/// Implementations must be `Sendable` so they can be injected into
/// `@MainActor`-isolated stores and called from concurrent contexts.
/// Each call to `narrate` creates an independent stream — implementations
/// must not share mutable state across calls.
protocol InsightNarrating: Sendable {
  /// Returns an async stream of cumulative narration snapshots. The stream
  /// ends cleanly when narration is complete, or finishes throwing
  /// `NarrationError.fellBack` when the output cannot be trusted (provenance
  /// check failed) or the underlying model errors — callers must then fall
  /// back to `TemplateNarrator`.
  func narrate(_ request: NarrationRequest) -> AsyncThrowingStream<String, any Error>
}

import Foundation

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
  nonisolated func narrate(_ request: NarrationRequest) -> AsyncThrowingStream<String, any Error>
}

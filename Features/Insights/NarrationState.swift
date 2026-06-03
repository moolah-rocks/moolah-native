import Foundation

/// The lifecycle of a per-insight narration request, keyed by insight id in
/// `InsightStore.narration`. Published on the main actor so the `ForYouCard`
/// can render streaming partial text and the final result.
///
/// `.fellBackToTemplate` is visually indistinguishable from `.done` in the UI
/// — the degradation is invisible to the user by design (issue #1042).
enum NarrationState: Sendable, Equatable {
  /// Narration has not started, or was cancelled.
  case idle
  /// Narration is in progress; the associated value is the partial text
  /// accumulated so far (may be empty at the very start of streaming).
  case streaming(String)
  /// Narration completed successfully; the associated value is the full text.
  case done(String)
  /// The on-device model failed or the provenance guard rejected its output;
  /// the template narrator's deterministic text is shown instead.
  case fellBackToTemplate(String)
}

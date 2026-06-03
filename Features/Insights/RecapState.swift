import Foundation

/// The lifecycle of the weekly-recap narration card.
///
/// `.hidden` is the default and the state after `dismiss()`. `.preparing`
/// renders a progress indicator while narration is in flight. `.ready` holds
/// the final two-sentence prose (either FM-generated or the template fallback
/// — the difference is invisible to the user).
enum RecapState: Sendable, Equatable {
  /// No recap to show. Either the opt-in is off, the model is unavailable,
  /// the recap was already shown this ISO week, or `dismiss()` was called.
  case hidden
  /// Narration is in progress. Renders a progress indicator.
  case preparing
  /// Narration completed; the associated value is the two-sentence prose.
  case ready(String)
}

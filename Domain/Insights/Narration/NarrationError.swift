import Foundation

/// Errors a narrator may throw into its output stream. Callers that receive
/// `.fellBack` should substitute the template narrator's output — the user
/// sees the deterministic fallback, not the error (issue #1042).
enum NarrationError {
  /// The narrator could not produce grounded output (provenance check failed
  /// or the model threw) — the caller must fall back to the template.
  case fellBack
}

extension NarrationError: Error {}

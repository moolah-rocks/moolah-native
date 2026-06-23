import Foundation

/// Deterministic, model-free narrator that composes a narration from the
/// request's title. Produces a single snapshot (the full composed string) and
/// finishes immediately.
///
/// Used in two roles:
/// 1. **Resilience fallback** — when the on-device model is available but a
///    generation call fails (provenance check rejected, model error, etc.).
/// 2. **CI fake / test double** — injected in tests and previews so no real
///    model is required.
struct TemplateNarrator {}

extension TemplateNarrator: InsightNarrating {
  nonisolated func narrate(_ request: NarrationRequest) -> AsyncThrowingStream<String, any Error> {
    let text = compose(request)
    return AsyncThrowingStream { continuation in
      continuation.yield(text)
      continuation.finish()
    }
  }
}

extension TemplateNarrator {
  private func compose(_ request: NarrationRequest) -> String {
    switch request {
    case let .singleInsight(kind, title, facts):
      return InsightDescriptionComposer.compose(kind: kind, title: title, facts: facts)
    }
  }
}

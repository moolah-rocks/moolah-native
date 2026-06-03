import Foundation

/// Deterministic, model-free narrator that composes a narration from the
/// request's title and facts. Produces a single snapshot (the full composed
/// string) and finishes immediately.
///
/// Used in two roles:
/// 1. **Resilience fallback** — when the on-device model is available but a
///    generation call fails (provenance check rejected, model error, etc.).
/// 2. **CI fake / test double** — injected in tests and previews so no real
///    model is required.
struct TemplateNarrator: InsightNarrating, Sendable {
  func narrate(_ request: NarrationRequest) -> AsyncThrowingStream<String, any Error> {
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
    case let .singleInsight(title, facts):
      return composeSingle(title: title, facts: facts)
    case let .weeklyRecap(items):
      return composeRecap(items: items)
    }
  }

  private func composeSingle(title: String, facts: [InsightFact]) -> String {
    guard !facts.isEmpty else { return title + "." }
    let factList = facts.map { "\($0.label): \($0.value)" }.joined(separator: ", ")
    return "\(title). \(factList)."
  }

  private func composeRecap(items: [NarrationRequest.Item]) -> String {
    guard !items.isEmpty else { return "Here's your weekly recap." }
    let parts = items.map { item -> String in
      let factList = item.facts.map { "\($0.label): \($0.value)" }.joined(separator: ", ")
      if factList.isEmpty {
        return item.title
      }
      return "\(item.title) (\(factList))"
    }
    return parts.joined(separator: "; ") + "."
  }
}

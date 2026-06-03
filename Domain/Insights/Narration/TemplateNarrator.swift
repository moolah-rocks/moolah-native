import Foundation

/// Deterministic, model-free narrator that composes a narration from the
/// request's detail sentence (or title as fallback). Produces a single snapshot
/// (the full composed string) and finishes immediately.
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
    case let .singleInsight(title, detail, _):
      return detail.isEmpty ? title : detail
    case let .weeklyRecap(items):
      return composeRecap(items: items)
    }
  }

  private func composeRecap(items: [NarrationRequest.Item]) -> String {
    guard !items.isEmpty else { return "" }
    switch items.count {
    case 1:
      return "This week: \(items[0].title)."
    case 2:
      return "This week: \(items[0].title) and \(items[1].title)."
    default:
      let allButLast = items.dropLast().map(\.title).joined(separator: ", ")
      return "This week: \(allButLast), and \(items[items.count - 1].title)."
    }
  }
}

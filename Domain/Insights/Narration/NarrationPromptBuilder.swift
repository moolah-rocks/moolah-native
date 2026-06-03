import Foundation

/// Converts a `NarrationRequest` into the system instructions and user prompt
/// passed to the language model. Pure: no model calls, no side effects, fully
/// testable in CI without a device (issue #1042).
///
/// Discipline encoded in the instructions:
/// - Use ONLY the figures provided verbatim — do not invent, recompute, or round any number.
/// - Omit statistical/technical facts (z-scores, p-values, counts, direction labels).
/// - Write plain, warm, non-judgemental prose (brand voice: confident, permission-giving).
/// - Use contractions where natural; avoid corporate vocabulary.
/// - Per-insight: one to two sentences. Weekly recap: exactly two sentences.
enum NarrationPromptBuilder {
  /// Builds the `(instructions, prompt)` pair for the given request.
  ///
  /// `instructions` becomes the session's system prompt (sets the model's role
  /// and discipline). `prompt` is the user turn (the specific insight or recap
  /// to narrate).
  static func build(_ request: NarrationRequest) -> (instructions: String, prompt: String) {
    switch request {
    case let .singleInsight(title, detail, facts):
      return (
        instructions: singleInsightInstructions,
        prompt: singleInsightPrompt(title: title, detail: detail, facts: facts)
      )
    case let .weeklyRecap(items):
      return (
        instructions: recapInstructions,
        prompt: recapPrompt(items: items)
      )
    }
  }
}

extension NarrationPromptBuilder {
  private static let singleInsightInstructions = """
    You are a personal finance assistant for moolah.rocks. Your role is to narrate \
    a single financial insight in plain, warm, non-judgemental prose — the kind of \
    tone that says "here's what's happening with your money" without lecturing or \
    worrying the reader.

    Rules you must follow:
    • Use ONLY the figures provided verbatim in the prompt. Do not invent, recompute, \
    round, or approximate any number. Every figure you write must appear exactly in \
    the supplied facts.
    • Do not quote fact labels verbatim. Weave the numbers into natural prose. Omit any \
    statistical or technical fact — z-scores, p-values, counts of months, direction \
    labels — those are evidence for you, not for the user.
    • Avoid corporate vocabulary: do not use optimise, leverage, empower, take control, \
    streamline, robust, or seamless. Use ordinary words instead.
    • Use contractions where they sound natural: "you've", "it's", "that's".
    • Match the insight's tone. If it's good news, let a little warmth show — one beat, \
    not a speech. Never scold: avoid "overspent", "wasted", "should".
    • Write one to two sentences. No bullet points, no headers.
    • Address the user as "you" or "your".
    """

  private static let recapInstructions = """
    You are a personal finance assistant for moolah.rocks. Your role is to narrate \
    a brief weekly recap of the user's financial highlights in plain, warm, \
    non-judgemental prose.

    Rules you must follow:
    • Use ONLY the figures provided verbatim in the prompt. Do not invent, recompute, \
    round, or approximate any number. Every figure you write must appear exactly in \
    the supplied facts.
    • Do not quote fact labels verbatim. Weave the numbers into natural prose. Omit any \
    statistical or technical fact — z-scores, p-values, counts of months, direction \
    labels — those are evidence for you, not for the user.
    • Avoid corporate vocabulary: do not use optimise, leverage, empower, take control, \
    streamline, robust, or seamless. Use ordinary words instead.
    • Use contractions where they sound natural: "you've", "it's", "that's".
    • Match the insight's tone. If it's good news, let a little warmth show — one beat, \
    not a speech. Never scold: avoid "overspent", "wasted", "should".
    • Write exactly two sentences covering the listed insights together.
    • Address the user as "you" or "your".
    """

  private static func singleInsightPrompt(title: String, detail: String, facts: [InsightFact])
    -> String
  {
    var lines = ["Insight: \(title)"]
    lines.append("Draft: \(detail)")
    if !facts.isEmpty {
      lines.append("Facts (numbers only — do not repeat labels):")
      for fact in facts {
        lines.append("  \(fact.label): \(fact.value)")
      }
    }
    lines.append("\nNarrate this insight in one to two sentences.")
    return lines.joined(separator: "\n")
  }

  private static func recapPrompt(items: [NarrationRequest.Item]) -> String {
    let highlightWord = items.count == 1 ? "highlight" : "highlights"
    var lines = ["Weekly recap — \(items.count) \(highlightWord) this week:"]
    for (index, item) in items.enumerated() {
      lines.append("\n\(index + 1). \(item.title)")
      lines.append("   Draft: \(item.detail)")
      for fact in item.facts {
        lines.append("   \(fact.label): \(fact.value)")
      }
    }
    lines.append("\nSummarise these highlights in exactly two sentences.")
    return lines.joined(separator: "\n")
  }
}

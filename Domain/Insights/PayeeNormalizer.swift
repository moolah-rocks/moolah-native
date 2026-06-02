import Foundation

/// Normalises a raw payee string into a stable clustering key for
/// subscription and new-merchant detection.
///
/// The design (`plans/2026-04-18-on-device-ai-design.md` §"Implementation
/// notes") calls for: lowercase, collapse whitespace, strip trailing
/// numerics / merchant-id noise. The transforms here are intentionally
/// conservative — the goal is to fold "STARBUCKS #1234" and "STARBUCKS
/// #5678  " onto the same key without merging genuinely different
/// merchants. It does *not* attempt LLM-grade merchant-name cleanup
/// (that's the cosmetic FM layer in the design).
enum PayeeNormalizer {
  /// Tokens that frequently prefix bank-statement descriptors and carry no
  /// merchant identity. Stripped only when they lead the string.
  private static let leadingNoise: Set<String> = [
    "pos", "sq", "tst", "paypal", "pp", "visa", "eftpos", "debit", "purchase",
    "payment", "card",
  ]

  /// Normalise an optional payee. Returns `""` for `nil` / blank input so
  /// callers can cheaply skip un-clusterable rows.
  static func normalize(_ payee: String?) -> String {
    guard let payee, !payee.isEmpty else { return "" }
    var working = payee.lowercased()

    // Replace any run of non-alphanumeric characters with a single space.
    working = working.replacingOccurrences(
      of: "[^a-z0-9]+", with: " ", options: .regularExpression)

    var tokens = working.split(separator: " ").map(String.init)

    // Drop a single leading noise token (e.g. "pos starbucks" → "starbucks").
    if let first = tokens.first, leadingNoise.contains(first) {
      tokens.removeFirst()
    }

    // Drop trailing tokens that are purely numeric or look like store /
    // reference ids (a digit anywhere). "starbucks 1234" → "starbucks".
    // Keep going while the last token is noise, but never strip the only
    // remaining alphabetic anchor.
    while tokens.count > 1, let last = tokens.last, isReferenceToken(last) {
      tokens.removeLast()
    }

    return tokens.joined(separator: " ")
  }

  /// A token that's all digits, or a short alphanumeric mix that contains a
  /// digit (store numbers, terminal ids, dates). Pure-alpha tokens are kept.
  private static func isReferenceToken(_ token: String) -> Bool {
    let hasDigit = token.contains(where: \.isNumber)
    guard hasDigit else { return false }
    let allDigits = token.allSatisfy(\.isNumber)
    return allDigits || token.count <= 6
  }
}

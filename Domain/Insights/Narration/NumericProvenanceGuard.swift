import Foundation

/// Verifies that every numeric token in model-generated text can be traced back
/// to a supplied fact value. A heuristic safety net: when it fails, the caller
/// falls back to `TemplateNarrator` rather than showing potentially invented
/// numbers to the user (issue #1042).
///
/// ## Normalisation
///
/// Normalisation is applied identically to both the generated text and the fact
/// values before comparison:
///
/// 1. Strip currency symbols (`$`, `€`, `£`, `¥`, `₹`, `₩`, `₿`) — they are
///    presentation wrappers, not part of the numeric identity.
/// 2. Strip a leading ASCII `+` — positive is the default; `+12.5%` and `12.5%`
///    are the same value.
/// 3. Canonicalize the Unicode minus `−` (U+2212) to ASCII `-` (U+002D) so a
///    model that outputs ASCII `-640.00` still matches a fact written `−640.00`
///    (U+2212). Sign identity is preserved — a genuine sign flip (negative fact,
///    positive generated text) still fails the guard.
/// 4. Strip thousands separators — a comma or period between digit groups
///    (e.g. `1,200` → `1200`). A period before 1–2 trailing digits is kept
///    as the decimal separator.
/// 5. Keep the negative sign and decimal separator intact. A model that drops
///    the sign produces a non-matching token, so the guard rejects it.
///
/// The guard errs toward rejection on ambiguity.
enum NumericProvenanceGuard {
  /// Returns `true` iff every numeric token extracted from `generated` appears
  /// verbatim in the normalised pool of grounded numbers.
  ///
  /// The grounded pool is the normalised numeric tokens of `title` plus the
  /// normalised value of every fact. The redesigned headline replaces the
  /// detector title, so a figure that lives only in the title (e.g. a
  /// net-worth milestone) is legitimately grounded; the title is trusted
  /// detector output, exactly like a fact value.
  ///
  /// A `true` result means narration passed; `false` means at least one number
  /// could not be traced to the title or supplied facts — the caller must fall
  /// back.
  static func isGrounded(_ generated: String, title: String, facts: [InsightFact]) -> Bool {
    let tokens = numericTokens(in: generated)
    guard !tokens.isEmpty else { return true }

    let titlePool = numericTokens(in: title).map { normalise($0) }
    let factPool = facts.map { normalise($0.value) }
    let groundedPool = titlePool + factPool

    for token in tokens {
      let normToken = normalise(token)
      guard groundedPool.contains(where: { $0 == normToken }) else {
        return false
      }
    }
    return true
  }

}

extension NumericProvenanceGuard {
  // MARK: - Token extraction

  /// Extracts numeric tokens from `text` by scanning Unicode scalars.
  ///
  /// Currency symbols are stripped first so a sign immediately before a
  /// currency symbol (e.g. `−$640.00`) becomes adjacent to the digit after
  /// stripping (`−640.00`), allowing the sign to be captured as part of the
  /// token. Interior separators (commas, dots) are included only when
  /// immediately followed by a digit, preventing trailing separators from
  /// contaminating the token.
  private static func numericTokens(in text: String) -> [String] {
    let currencySymbols: Set<Unicode.Scalar> = ["$", "€", "£", "¥", "₹", "₩", "₿"]
    let stripped = String(text.unicodeScalars.filter { !currencySymbols.contains($0) })
    let scalars = Array(stripped.unicodeScalars)

    var tokens: [String] = []
    var index = 0
    while index < scalars.count {
      if let (token, nextIndex) = extractToken(from: scalars, at: index) {
        tokens.append(token)
        index = nextIndex
      } else {
        index += 1
      }
    }
    return tokens
  }

  /// Attempts to extract a single numeric token starting at `position`.
  /// Returns the token string and the index of the next unscanned character,
  /// or `nil` if no token starts at `position`.
  private static func extractToken(
    from scalars: [Unicode.Scalar],
    at position: Int
  ) -> (token: String, nextIndex: Int)? {
    // 0x2B = '+', 0x2D = '-', 0x2212 = '−' (Unicode MINUS SIGN).
    let scalar = scalars[position]
    let isSign = scalar.value == 0x2B || scalar.value == 0x2D || scalar.value == 0x2212
    let isDigit = scalar.value >= 48 && scalar.value <= 57

    let startsWithSign =
      isSign
      && position + 1 < scalars.count
      && scalars[position + 1].value >= 48
      && scalars[position + 1].value <= 57
    let startsWithDigit = isDigit

    guard startsWithSign || startsWithDigit else { return nil }

    var tokenScalars: [Unicode.Scalar] = []
    var cursor = position

    if startsWithSign {
      tokenScalars.append(scalars[cursor])
      cursor += 1
    }

    guard cursor < scalars.count,
      scalars[cursor].value >= 48,
      scalars[cursor].value <= 57
    else { return nil }

    cursor = consumeDigitGroup(from: scalars, into: &tokenScalars, at: cursor)

    // Consume optional trailing percent. 0x25 = '%'.
    if cursor < scalars.count, scalars[cursor].value == 0x25 {
      tokenScalars.append(scalars[cursor])
      cursor += 1
    }

    let token = String(String.UnicodeScalarView(tokenScalars))
    guard token.unicodeScalars.contains(where: { $0.value >= 48 && $0.value <= 57 }) else {
      return nil
    }
    return (token, cursor)
  }

  /// Consumes digit groups — digits, and separators (commas/dots) that are
  /// immediately followed by another digit — into `output`, starting at
  /// `position`. Returns the index of the first un-consumed character.
  private static func consumeDigitGroup(
    from scalars: [Unicode.Scalar],
    into output: inout [Unicode.Scalar],
    at position: Int
  ) -> Int {
    var cursor = position
    while cursor < scalars.count {
      let scalar = scalars[cursor]
      let isDigit = scalar.value >= 48 && scalar.value <= 57
      // 0x2C = ',', 0x2E = '.'
      let isSeparator = scalar.value == 0x2C || scalar.value == 0x2E

      if isDigit {
        output.append(scalar)
        cursor += 1
      } else if isSeparator,
        cursor + 1 < scalars.count,
        scalars[cursor + 1].value >= 48,
        scalars[cursor + 1].value <= 57
      {
        output.append(scalar)
        cursor += 1
      } else {
        break
      }
    }
    return cursor
  }

  // MARK: - Normalisation

  /// Normalises a raw numeric string (token or fact value) to a canonical form
  /// for equality comparison. See the type-level documentation for the full
  /// normalisation rules.
  private static func normalise(_ raw: String) -> String {
    var working = raw

    // 1. Strip common currency symbols.
    let currencySymbols: Set<Character> = ["$", "€", "£", "¥", "₹", "₩", "₿"]
    working = String(working.filter { !currencySymbols.contains($0) })

    // 2. Strip a leading ASCII `+` (positive is the default).
    if working.hasPrefix("+") {
      working = String(working.dropFirst())
    }

    // 3. Canonicalize the Unicode minus sign (U+2212) to ASCII hyphen-minus
    //    (U+002D). Detectors emit U+2212; LLMs emit ASCII. Unifying the
    //    codepoint lets them compare equal while preserving sign identity —
    //    a genuine sign flip still produces a mismatch after normalisation.
    working = working.replacingOccurrences(of: "\u{2212}", with: "-")

    // 4. Collapse thousands separators.
    return collapseThousandsSeparators(in: working)
  }

  /// Drops commas and periods that are thousands separators (followed by 3+
  /// digits) while preserving decimal separators (followed by 1–2 digits).
  private static func collapseThousandsSeparators(in value: String) -> String {
    var result = ""
    let chars = Array(value)
    var index = 0
    while index < chars.count {
      let char = chars[index]
      if char == "," || char == ".",
        index > 0,
        index < chars.count - 1,
        chars[index - 1].isNumber,
        chars[index + 1].isNumber
      {
        let remainingDigits = countLeadingDigits(chars, from: index + 1)
        if remainingDigits >= 3 {
          index += 1
          continue  // Thousands separator — drop it.
        }
        // Decimal separator — keep it.
      }
      result.append(char)
      index += 1
    }
    return result
  }

  /// Counts consecutive ASCII digit characters starting at `startIndex`.
  private static func countLeadingDigits(_ chars: [Character], from startIndex: Int) -> Int {
    var count = 0
    var index = startIndex
    while index < chars.count, chars[index].isNumber {
      count += 1
      index += 1
    }
    return count
  }
}

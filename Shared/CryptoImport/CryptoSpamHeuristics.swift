import Foundation

/// Local, deterministic spam heuristics for discovered crypto tokens, applied
/// purely to a token's name and symbol — no network round-trip.
///
/// These implement issue #1102 bullets 4 and 5:
/// * a URL or domain name embedded in the token name (scam airdrops point the
///   holder at a phishing site);
/// * "invitation" / airdrop / voucher scam phrasing.
///
/// Crucially, the caller (`CryptoTokenDiscoveryService`) only consults these
/// for tokens that did **not** resolve to a price provider. A legitimately
/// listed token whose name happens to contain a domain — e.g. `yearn.finance`
/// (YFI) — resolves on CoinGecko and keeps its `.priced` status, so the
/// domain rule never demotes it. The heuristics only ever turn an otherwise
/// `.unpriced` token into `.spam`, which the user can still override.
enum CryptoSpamHeuristics {
  /// Why a token was classified as spam by the local heuristics.
  enum SpamSignal: String, Sendable {
    /// The name or symbol contains a URL or a `label.tld` domain.
    case embeddedURL
    /// The name or symbol contains airdrop / invitation / voucher phrasing.
    case scamKeyword
    /// The symbol mixes Latin with another script (a homoglyph spoof of a
    /// popular ASCII ticker, e.g. `USD` + Cyrillic `Es`).
    case mixedScriptSymbol
  }

  /// Returns the heuristic that classifies `(name, symbol)` as spam, or `nil`
  /// when the token shows no name-based spam signal. URL/domain detection
  /// takes precedence over keyword detection so the reported reason reflects
  /// the strongest signal.
  static func spamSignal(name: String, symbol: String?) -> SpamSignal? {
    let haystack = ([name, symbol ?? ""].joined(separator: " "))
      .lowercased()
    guard !haystack.allSatisfy(\.isWhitespace) else { return nil }
    if containsURLOrDomain(haystack) { return .embeddedURL }
    if containsScamKeyword(haystack) { return .scamKeyword }
    if let symbol, isMixedScript(symbol) { return .mixedScriptSymbol }
    return nil
  }

  /// Convenience boolean wrapper over `spamSignal(name:symbol:)`.
  static func isLikelySpam(name: String, symbol: String?) -> Bool {
    spamSignal(name: name, symbol: symbol) != nil
  }

  // MARK: - URL / domain detection

  private static func containsURLOrDomain(_ haystack: String) -> Bool {
    if haystack.contains("http://") || haystack.contains("https://")
      || haystack.contains("www.")
    {
      return true
    }
    return matches(domainRegex, in: haystack)
  }

  /// Matches a `label.tld` domain where `tld` is a common (and scam-favoured)
  /// top-level domain. The leading negative lookbehind keeps the match
  /// anchored to a label boundary; the trailing lookahead stops a TLD from
  /// matching the prefix of a longer word.
  private static let domainRegex: NSRegularExpression = {
    let tlds = [
      "com", "net", "org", "io", "co", "xyz", "app", "finance", "fi", "site",
      "click", "vip", "top", "live", "info", "me", "biz", "online", "store",
      "gift", "cash", "money", "fund", "win", "pro", "gg", "lol", "cc", "ru",
      "cn", "tk", "ml", "ga", "cf", "gq", "fun", "monster", "icu", "li", "sh",
      "ws", "in", "us", "to", "ai", "dev", "page", "link",
    ].joined(separator: "|")
    let pattern = "(?<![a-z0-9])[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\.(?:\(tlds))(?![a-z0-9])"
    return compile(pattern)
  }()

  // MARK: - Scam keyword detection

  /// Words that are textbook in airdrop / voucher / "invitation" scam tokens
  /// and essentially never lead a word in a legitimate token's name. The
  /// negative lookbehind anchors each match to the start of a word, so
  /// "claim" fires on "Claim your reward" but not on "Reclaim Protocol" or
  /// "Disclaimer"; trailing characters are unconstrained so plural/inflected
  /// forms ("rewards", "claims") still match.
  private static let scamKeywordRegex: NSRegularExpression = {
    let keywords = [
      "airdrop", "invitation", "invite", "voucher", "giveaway", "redeem",
      "presale", "claim", "reward", "winner", "you won", "free entry",
    ].joined(separator: "|")
    return compile("(?<![a-z0-9])(?:\(keywords))")
  }()

  private static func containsScamKeyword(_ haystack: String) -> Bool {
    matches(scamKeywordRegex, in: haystack)
  }

  // MARK: - Mixed-script (homoglyph) detection

  /// Returns `true` when `symbol` mixes a Latin letter with a letter from
  /// another script. Legitimate tickers are pure ASCII/Latin; a spam contract
  /// spoofs a popular ticker by swapping one Latin letter for a visually
  /// identical character from another script — e.g. Cyrillic `Es` (U+0421)
  /// for Latin `C` to fake "USDC". Such a symbol renders as the target ticker
  /// but is not byte-equal to it, so the canonical-registry impersonation
  /// check (exact match) misses it; this signal closes that gap.
  ///
  /// Pure single-script symbols are intentionally not flagged: an all-Latin
  /// ticker is the normal case, and an all-non-Latin ticker cannot read as a
  /// Latin target (the spoof must keep the Latin letters that lack a
  /// convincing confusable, so the result is always mixed).
  private static func isMixedScript(_ symbol: String) -> Bool {
    var hasLatin = false
    var hasNonLatin = false
    for scalar in symbol.unicodeScalars where scalar.properties.isAlphabetic {
      if isLatinLetter(scalar) { hasLatin = true } else { hasNonLatin = true }
      if hasLatin && hasNonLatin { return true }
    }
    return false
  }

  /// Whether `scalar` is a letter in the Latin script: Basic Latin, Latin-1
  /// Supplement, and Latin Extended-A/B/Additional. Any alphabetic scalar
  /// outside these blocks counts as another script for mixed-script detection.
  private static func isLatinLetter(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x41...0x5A, 0x61...0x7A,  // A–Z, a–z
      0xC0...0x24F,  // Latin-1 Supplement + Latin Extended-A/B
      0x1E00...0x1EFF:  // Latin Extended Additional
      return true
    default:
      return false
    }
  }

  // MARK: - Regex plumbing

  /// Compiles a pattern that is a compile-time constant. A failure here can
  /// only mean a maintainer garbled the pattern string, so trap loudly rather
  /// than silently classify every token as not-spam.
  ///
  /// The returned `NSRegularExpression` is stored in a `static let` and never
  /// mutated after init; `NSRegularExpression` is documented as safe for
  /// concurrent use from multiple threads for matching, so sharing the compiled
  /// instance across actors (e.g. `CryptoTokenDiscoveryService`) is race-free.
  private static func compile(_ pattern: String) -> NSRegularExpression {
    do {
      return try NSRegularExpression(pattern: pattern)
    } catch {
      fatalError("CryptoSpamHeuristics: invalid regex pattern '\(pattern)' — \(error)")
    }
  }

  private static func matches(_ regex: NSRegularExpression, in haystack: String) -> Bool {
    let range = NSRange(haystack.startIndex..., in: haystack)
    return regex.firstMatch(in: haystack, range: range) != nil
  }
}

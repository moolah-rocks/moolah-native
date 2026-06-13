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

  // MARK: - Regex plumbing

  /// Compiles a pattern that is a compile-time constant. A failure here can
  /// only mean a maintainer garbled the pattern string, so trap loudly rather
  /// than silently classify every token as not-spam.
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

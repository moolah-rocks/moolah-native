/// Sidebar bucket that an account (or group of accounts) lives in.
///
/// Designed for future extension: additional cases (`.savings`,
/// `.retirement`, `.liabilities`) can be added when the product wants
/// them; the raw-value tokens are stable wire identifiers and must not
/// be renamed. Long-term, this may become a value type referencing
/// user-defined buckets — adding the abstraction now is YAGNI.
enum AccountBucket: String, Codable, Sendable, CaseIterable {
  case current
  case investments
}

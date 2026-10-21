import Foundation

/// Internal keyset boundary; transports must authenticate any serialized cursor.
struct ReadPageKey: Codable, Sendable, Equatable {
  let id: UUID
  var date: Date?
}

struct ReadPageRequest: Sendable {
  let limit: Int
  let after: ReadPageKey?
  let revision: String?

  init(
    limit: Int = 100,
    after: ReadPageKey? = nil,
    revision: String? = nil
  ) throws {
    guard (1...500).contains(limit), after == nil || revision != nil else {
      throw ReadQueryError.invalidFilter
    }
    self.limit = limit
    self.after = after
    self.revision = revision
  }
}

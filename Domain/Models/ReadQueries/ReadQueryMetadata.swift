import Foundation

struct ReadQueryMetadata: Codable, Sendable {
  let queriedAt: Date
  let profileID: UUID
  let timeZone: String
  let localRevision: String
  let consistency: String
  let syncState: String
  let warnings: [String]
}

/// Never encoded directly: a transport must authenticate and encode its continuation cursor.
struct ReadQueryResponse<Element: Codable & Sendable>: Sendable {
  let metadata: ReadQueryMetadata
  let items: [Element]
  let nextKey: ReadPageKey?
}

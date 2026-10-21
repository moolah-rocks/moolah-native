import Foundation

/// One bounded database snapshot. Concurrent writes invalidate its continuation revision.
struct ReadPage<Element: Sendable>: Sendable {
  let items: [Element]
  let revision: String
  let queriedAt: Date
  let nextKey: ReadPageKey?

  var hasMore: Bool { nextKey != nil }
}

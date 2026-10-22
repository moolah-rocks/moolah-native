import Foundation

/// Validated balance selection, account pagination and requested detail level.
struct ReadBalanceQuery: Sendable {
  let accountIDs: Set<UUID>
  let page: ReadPageRequest
  let includePositions: Bool
}

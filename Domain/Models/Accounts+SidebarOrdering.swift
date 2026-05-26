import Foundation

/// A single entry in a bucket section: either a standalone account or a
/// group with its members. Standalone accounts and groups compete in the
/// same `position` number space within a bucket; the sidebar renders
/// them intermixed.
enum SidebarBucketEntry: Equatable {
  case account(Account)
  case group(AccountGroup, members: [Account])

  /// Stable identifier suitable for SwiftUI `ForEach` keying. The
  /// account / group UUID is unique across the entry list because a
  /// member account doesn't appear as its own top-level entry.
  var bucketEntryId: UUID {
    switch self {
    case .account(let account): return account.id
    case .group(let group, _): return group.id
    }
  }
}

extension Accounts {
  struct SidebarGroups: Equatable {
    let current: [Account]
    let investments: [Account]
  }

  /// Group-aware sidebar grouping. Returns standalone accounts and
  /// groups intermixed per bucket, sorted by their shared `position`.
  /// Within a group, members are returned sorted by member `position`.
  struct GroupAwareSidebarGroups: Equatable {
    let current: [SidebarBucketEntry]
    let investments: [SidebarBucketEntry]
  }

  /// Accounts grouped and sorted the way the sidebar shows them.
  ///
  /// - Parameters:
  ///   - excluding: Account id to drop entirely. Used by the transfer
  ///     counterpart picker to remove the from-account from the
  ///     candidate list.
  ///   - alwaysInclude: Account id to keep visible even when hidden.
  ///     Used by pickers so an already-selected account that is
  ///     hidden stays in the dropdown.
  /// - Returns: Two arrays — `current` (bank, asset, credit card) and
  ///   `investments` — each sorted ascending by `Account.position`.
  /// - Note: When `excluding` and `alwaysInclude` reference the same
  ///   id, exclusion wins.
  func sidebarGrouped(
    excluding: UUID? = nil,
    alwaysInclude: UUID? = nil
  ) -> SidebarGroups {
    let visible = ordered.filter { account in
      if account.id == excluding { return false }
      if account.isHidden && account.id != alwaysInclude { return false }
      return true
    }
    var current: [Account] = []
    var investments: [Account] = []
    for account in visible {
      switch account.bucket {
      case .current:
        current.append(account)
      case .investments:
        investments.append(account)
      }
    }
    return SidebarGroups(current: current, investments: investments)
  }

  /// Flat sidebar-ordered list (current first, then investment) with
  /// the same hidden / exclusion rules as ``sidebarGrouped(excluding:alwaysInclude:)``.
  func sidebarOrdered(
    excluding: UUID? = nil,
    alwaysInclude: UUID? = nil
  ) -> [Account] {
    let groups = sidebarGrouped(excluding: excluding, alwaysInclude: alwaysInclude)
    return groups.current + groups.investments
  }

  /// Returns standalone accounts (`groupId == nil`) and groups intermixed
  /// per bucket, sorted by their shared `position`. Members of a group
  /// are returned alongside their group entry, sorted by member
  /// `position`. Honours the same hidden / exclusion rules as
  /// `sidebarGrouped(excluding:alwaysInclude:)` — a hidden member is
  /// excluded from its group's member list (the group still renders).
  ///
  /// Tie-break when a standalone account and a group share the same
  /// `position` value: standalone account renders first, then the
  /// group. This is a deterministic-ordering choice — sync conflict on
  /// `position` should resolve to a stable display order.
  ///
  /// Cross-bucket invariant: a group with `bucket == .investments` only
  /// appears in the investments bucket. Hypothetical members with a
  /// different bucket would not be included — the helper trusts
  /// `group.bucket` for placement.
  func groupAwareSidebar(
    groups: [AccountGroup],
    excluding: UUID? = nil,
    alwaysInclude: UUID? = nil
  ) -> GroupAwareSidebarGroups {
    let visible = ordered.filter { account in
      if account.id == excluding { return false }
      if account.isHidden && account.id != alwaysInclude { return false }
      return true
    }
    return GroupAwareSidebarGroups(
      current: entries(for: .current, visible: visible, groups: groups),
      investments: entries(for: .investments, visible: visible, groups: groups)
    )
  }

  private func entries(
    for bucket: AccountBucket,
    visible: [Account],
    groups: [AccountGroup]
  ) -> [SidebarBucketEntry] {
    let knownGroupIds = Set(groups.map(\.id))
    // Standalone = no groupId, OR a dangling groupId pointing at an
    // unknown group (sync delivery can place an Account ahead of its
    // AccountGroup — see spec §"Sync & schema").
    let standalone = visible.filter { account in
      guard account.bucket == bucket else { return false }
      guard let gid = account.groupId else { return true }
      return !knownGroupIds.contains(gid)
    }
    let bucketGroups = groups.filter { $0.bucket == bucket }
    let groupEntries: [SidebarBucketEntry] = bucketGroups.map { group in
      let members =
        visible
        .filter { $0.groupId == group.id }
        .sorted { $0.position < $1.position }
      return .group(group, members: members)
    }
    let standaloneEntries: [SidebarBucketEntry] = standalone.map { .account($0) }
    return (standaloneEntries + groupEntries).sorted(by: Self.entryOrdering)
  }

  /// Sort key for intermixed standalone-account / group entries. Standalone
  /// accounts and groups compete in the same `position` space; equal
  /// positions tie-break with standalone-account-first so the order is
  /// deterministic across sync conflicts.
  private static func entryOrdering(
    _ lhs: SidebarBucketEntry, _ rhs: SidebarBucketEntry
  ) -> Bool {
    let lhsPos = position(of: lhs)
    let rhsPos = position(of: rhs)
    if lhsPos != rhsPos { return lhsPos < rhsPos }
    return tieBreakWeight(lhs) < tieBreakWeight(rhs)
  }

  private static func position(of entry: SidebarBucketEntry) -> Int {
    switch entry {
    case .account(let account): return account.position
    case .group(let group, _): return group.position
    }
  }

  /// 0 = standalone account, 1 = group — sorting account-first when
  /// positions tie.
  private static func tieBreakWeight(_ entry: SidebarBucketEntry) -> Int {
    switch entry {
    case .account: return 0
    case .group: return 1
    }
  }
}

import Foundation

/// Pure, side-effect-free translation between the outline view's
/// per-row expansion `Set<SidebarRow>` and the persisted group
/// expansion `Set<UUID>` owned by `GroupUIStateStore`. Section
/// headers always render expanded by default and never persist their
/// state, so the only rows that survive a round trip are `.group(_)`.
enum SidebarOutlineExpansion {
  /// Lifts each group id into a `.group` `SidebarRow`. Non-group rows
  /// are never emitted by this function.
  static func rows(for groupIds: Set<UUID>) -> Set<SidebarRow> {
    Set(groupIds.map(SidebarRow.group))
  }

  /// Returns just the group ids embedded in `.group` rows. All other
  /// `SidebarRow` cases — section / account / earmark / total /
  /// navigation — are silently dropped.
  static func groupIds(in rows: Set<SidebarRow>) -> Set<UUID> {
    Set(
      rows.compactMap { row in
        if case .group(let id) = row { id } else { nil }
      })
  }
}

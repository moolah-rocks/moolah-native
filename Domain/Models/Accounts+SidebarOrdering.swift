import Foundation

extension Accounts {
  struct SidebarGroups: Equatable {
    let current: [Account]
    let investments: [Account]
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
}

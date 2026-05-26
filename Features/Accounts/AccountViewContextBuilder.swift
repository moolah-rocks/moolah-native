import Foundation

/// Builds the `AccountViewContext` the composite detail view binds to
/// from a `SidebarSelection` and the latest store snapshots. Pure
/// function — no observation, no async — so it can be called from the
/// detail-view layer on every render without coupling to a store.
///
/// Selections that don't render a detail view (`.earmark`,
/// `.allTransactions`, `.reports`, etc.) return `nil`; the caller falls
/// back to the existing route for that selection.
enum AccountViewContextBuilder {
  static func build(
    for selection: SidebarSelection,
    accounts: Accounts,
    groups: [AccountGroup],
    syncStatuses: [UUID: AccountSyncStatus]
  ) -> AccountViewContext? {
    switch selection {
    case .account(let id):
      return buildAccountContext(id: id, accounts: accounts, syncStatuses: syncStatuses)
    case .group(let id):
      return buildGroupContext(
        id: id, accounts: accounts, groups: groups, syncStatuses: syncStatuses)
    case .earmark, .recentlyAdded, .allTransactions, .upcomingTransactions,
      .categories, .reports, .analysis:
      return nil
    }
  }

  private static func buildAccountContext(
    id: UUID,
    accounts: Accounts,
    syncStatuses: [UUID: AccountSyncStatus]
  ) -> AccountViewContext? {
    guard let account = accounts.by(id: id) else { return nil }
    let perAccount = [syncStatuses[account.id]].compactMap { $0 }
    return AccountViewContext(
      kind: .account,
      displayName: account.name,
      displayInstrument: account.instrument,
      bucket: account.bucket,
      accountIds: [account.id],
      syncStatus: AggregatedSyncStatus.aggregate(perAccount))
  }

  private static func buildGroupContext(
    id: UUID,
    accounts: Accounts,
    groups: [AccountGroup],
    syncStatuses: [UUID: AccountSyncStatus]
  ) -> AccountViewContext? {
    guard let group = groups.first(where: { $0.id == id }) else { return nil }
    let members =
      accounts.ordered
      .filter { $0.groupId == group.id }
      .sorted { $0.position < $1.position }
    let memberStatuses = members.compactMap { syncStatuses[$0.id] }
    return AccountViewContext(
      kind: .group,
      displayName: group.name,
      displayInstrument: group.instrument,
      bucket: group.bucket,
      accountIds: members.map(\.id),
      syncStatus: AggregatedSyncStatus.aggregate(memberStatuses))
  }
}

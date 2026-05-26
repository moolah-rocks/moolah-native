import SwiftUI

extension ContentView {
  /// Composite detail view for an `AccountGroup` selection. Builds an
  /// `AccountViewContext` from the live store snapshots and binds the
  /// detail surface to it. When the group is unknown (e.g. still
  /// arriving via sync), renders an "unavailable" placeholder so the
  /// user has clear feedback that the selection didn't resolve.
  @ViewBuilder
  func groupDetail(id: UUID) -> some View {
    if let context = AccountViewContextBuilder.build(
      for: .group(id),
      accounts: accountStore.accounts,
      groups: accountGroupStore.groups,
      syncStatuses: groupSyncStatuses(for: id))
    {
      GroupDetailView(
        context: context,
        accounts: accountStore.accounts,
        categories: categoryStore.categories,
        earmarks: earmarkStore.earmarks,
        transactionStore: transactionStore,
        conversionService: session.backend.conversionService)
    } else {
      ContentUnavailableView(
        "Group not found",
        systemImage: "folder.badge.questionmark",
        description: Text("This group may not have arrived from sync yet."))
    }
  }

  /// Builds a per-member `AccountSyncStatus` map for the supplied
  /// group's members. Reads from `ProfileSession.cryptoSyncStore` so
  /// the aggregator collapses correctly when the profile has no sync
  /// surface (returns an empty map → `.allSynced`).
  private func groupSyncStatuses(for groupId: UUID) -> [UUID: AccountSyncStatus] {
    guard let syncStore = session.cryptoSyncStore else { return [:] }
    let members = accountStore.accounts.ordered.filter { $0.groupId == groupId }
    var result: [UUID: AccountSyncStatus] = [:]
    for member in members {
      result[member.id] = AccountSyncStatus(
        accountId: member.id,
        isInProgress: syncStore.inProgressAccountIds.contains(member.id),
        hasError: syncStore.statePerAccount[member.id]?.lastError != nil)
    }
    return result
  }
}

import Foundation

// Mutation surface for `AccountGroupStore`.
//
// Mutations are pass-through under the reactive design: every method
// calls the repository, the GRDB write commits, and
// `repository.observeAll()` delivers the authoritative state via the
// observation task spawned in `AccountGroupStore.init`. There is no
// optimistic insert / rollback path — the reactive emission IS the
// state update.
//
// Cross-store coordination (membership) is via the caller passing an
// `AccountStore` directly. This keeps the dependency direction explicit
// (groups depend on accounts; accounts don't know about groups) and
// avoids retain cycles.
extension AccountGroupStore {

  /// Creates a single-member group from `account`. The new group's
  /// bucket and instrument are derived from the source account; the
  /// account's `groupId` is updated to point at the new group and its
  /// `position` is set to 0 (first member).
  ///
  /// The reactive observation streams deliver both writes (group create
  /// and account update) via their respective stores' `observeAll()`
  /// subscriptions shortly after the writes commit.
  @discardableResult
  func createGroup(
    from account: Account,
    name: String,
    accountStore: AccountStore
  ) async throws -> AccountGroup {
    setError(nil)
    let group = AccountGroup(
      name: name,
      bucket: account.bucket,
      instrument: account.instrument,
      position: nextGroupPosition(in: account.bucket)
    )
    do {
      let created = try await repository.create(group)
      var moved = account
      moved.groupId = created.id
      moved.position = 0
      _ = try await accountStore.update(moved)
      return created
    } catch {
      logger.error("Failed to create group: \(error.localizedDescription)")
      setError(error)
      throw error
    }
  }

  /// Creates a 2-member group joining `accountA` and `accountB`. Both
  /// accounts' `groupId` is set; member positions are assigned in the
  /// order of the arguments (A = 0, B = 1).
  ///
  /// Precondition: both accounts share the same bucket. Cross-bucket
  /// grouping is prohibited by the UI; the precondition is a safety
  /// belt for programmer error.
  @discardableResult
  func createGroup(
    joining accountA: Account,
    and accountB: Account,
    name: String,
    accountStore: AccountStore
  ) async throws -> AccountGroup {
    precondition(
      accountA.bucket == accountB.bucket,
      "cross-bucket grouping prohibited")
    setError(nil)
    let group = AccountGroup(
      name: name,
      bucket: accountA.bucket,
      instrument: accountA.instrument,
      position: nextGroupPosition(in: accountA.bucket)
    )
    do {
      let created = try await repository.create(group)
      for (idx, account) in [accountA, accountB].enumerated() {
        var member = account
        member.groupId = created.id
        member.position = idx
        _ = try await accountStore.update(member)
      }
      return created
    } catch {
      logger.error("Failed to create group joining two accounts: \(error.localizedDescription)")
      setError(error)
      throw error
    }
  }

  /// Adds `account` as a member of `group`. The account's `groupId` is
  /// set and its `position` is appended to the end of the group's
  /// current member list. Same-bucket constraint is enforced by
  /// precondition.
  func addAccount(
    _ account: Account,
    to group: AccountGroup,
    accountStore: AccountStore
  ) async throws {
    precondition(
      account.bucket == group.bucket,
      "cross-bucket grouping prohibited")
    setError(nil)
    do {
      var member = account
      member.groupId = group.id
      member.position = membersCount(of: group.id, in: accountStore)
      _ = try await accountStore.update(member)
    } catch {
      logger.error("Failed to add account to group: \(error.localizedDescription)")
      setError(error)
      throw error
    }
  }

  /// Removes `account` from its current group (if any). Auto-deletes
  /// the group if it becomes empty. Clears `Account.groupId` and
  /// re-positions the account to the end of its bucket's standalone
  /// list.
  ///
  /// No-op when the account already has no group.
  func removeAccount(
    _ account: Account,
    accountStore: AccountStore
  ) async throws {
    guard let groupId = account.groupId else { return }
    setError(nil)
    do {
      var standalone = account
      standalone.groupId = nil
      standalone.position = nextStandalonePosition(
        in: account.bucket, accountStore: accountStore)
      _ = try await accountStore.update(standalone)

      // Auto-delete the group if no other members remain. Check via the
      // post-update accountStore snapshot — the just-updated account
      // hasn't observed back yet, so iterate the ordered list filtering
      // on groupId and the account's id.
      let stillMembers = accountStore.accounts.ordered.contains { other in
        other.groupId == groupId && other.id != account.id
      }
      if !stillMembers {
        try await repository.delete(id: groupId)
      }
    } catch {
      logger.error("Failed to remove account from group: \(error.localizedDescription)")
      setError(error)
      throw error
    }
  }

  /// Trim-and-no-op rename, matching `AccountStore.rename(id:to:)` and
  /// `EarmarkStore.rename(id:to:)`. Empty / whitespace-only / same-name
  /// input is a no-op (no write).
  @discardableResult
  func rename(id: UUID, to newName: String) async throws -> AccountGroup? {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let group = by(id: id) else { return nil }
    guard !trimmed.isEmpty, trimmed != group.name else { return group }
    setError(nil)
    do {
      var updated = group
      updated.name = trimmed
      return try await repository.update(updated)
    } catch {
      logger.error("Failed to rename group: \(error.localizedDescription)")
      setError(error)
      throw error
    }
  }

  /// Updates a group's `position`. Used by the sidebar reorder path.
  /// The reactive observation delivers the updated position.
  func moveGroup(_ group: AccountGroup, to newPosition: Int) async throws {
    setError(nil)
    do {
      var updated = group
      updated.position = newPosition
      _ = try await repository.update(updated)
    } catch {
      logger.error("Failed to move group: \(error.localizedDescription)")
      setError(error)
      throw error
    }
  }

  // MARK: - Helpers

  /// Returns the next free `position` for a new group in `bucket`. The
  /// new group lands at the end of the bucket's group list (groups and
  /// standalone accounts compete in the same position space, but a new
  /// group's position is computed only against existing groups in the
  /// bucket — the sidebar ordering layer interleaves them).
  private func nextGroupPosition(in bucket: AccountBucket) -> Int {
    let inBucket = groups.filter { $0.bucket == bucket }
    return (inBucket.map(\.position).max() ?? -1) + 1
  }

  /// Returns the count of members currently associated with `groupId`,
  /// used as the next member position when appending. Reads from
  /// `accountStore.accounts.ordered` — the most up-to-date view, even
  /// before a fresh observation tick.
  private func membersCount(
    of groupId: UUID, in accountStore: AccountStore
  ) -> Int {
    accountStore.accounts.ordered.filter { $0.groupId == groupId }.count
  }

  /// Returns the next free `position` for a standalone account in
  /// `bucket`. Used when a member is removed from a group and becomes
  /// standalone — it lands at the end of the bucket's flat ordering.
  private func nextStandalonePosition(
    in bucket: AccountBucket, accountStore: AccountStore
  ) -> Int {
    let inBucket = accountStore.accounts.ordered.filter {
      $0.bucket == bucket && $0.groupId == nil
    }
    return (inBucket.map(\.position).max() ?? -1) + 1
  }
}

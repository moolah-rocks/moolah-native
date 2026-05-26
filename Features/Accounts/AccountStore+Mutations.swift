import Foundation
import OSLog

// Mutation surface for `AccountStore`.
//
// Mutations are pass-through under the reactive design: every method
// calls the repository, the GRDB write commits, and
// `repository.observeAll()` delivers the authoritative state via the
// observation task spawned in `AccountStore.init`. There is no
// optimistic insert / rollback path — the reactive emission IS the
// state update.
extension AccountStore {
  /// Pass-through create. The reactive observation delivers the new
  /// account via `observeAll()` shortly after the GRDB write commits;
  /// no optimistic insert is needed and there is nothing to roll back
  /// because no local state was mutated. Errors surface on `self.error`
  /// and are rethrown for the caller.
  func create(
    _ account: Account, openingBalance: InstrumentAmount? = nil
  ) async throws -> Account {
    setError(nil)

    // User-driven account creation lands in trades mode by default for
    // investment accounts: any caller-provided `.recordedValue` is silently
    // promoted to `.calculatedFromTrades`. Migration / sync paths that need
    // to write `.recordedValue` go through `accountRepository.update(_:)`
    // directly, not this method.
    var toCreate = account
    if toCreate.type == .investment && toCreate.valuationMode == .recordedValue {
      toCreate.valuationMode = .calculatedFromTrades
    }

    do {
      let created = try await mutationRepository.create(
        toCreate, openingBalance: openingBalance)
      mutationLogger.debug("Created account: \(created.name)")
      return created
    } catch {
      mutationLogger.error("Failed to create account: \(error.localizedDescription)")
      setError(error)
      throw error
    }
  }

  /// Pass-through update. See `create(_:openingBalance:)` for the
  /// rationale; the reactive observation delivers the updated account.
  func update(_ account: Account) async throws -> Account {
    setError(nil)
    do {
      let updated = try await mutationRepository.update(account)
      mutationLogger.debug("Updated account: \(updated.name)")
      return updated
    } catch {
      mutationLogger.error("Failed to update account: \(error.localizedDescription)")
      setError(error)
      throw error
    }
  }

  /// Convenience rename for the inline-rename UI flow. Trims whitespace;
  /// treats empty / whitespace-only input as a no-op (no write; returns the
  /// current account unchanged). Same-name input is also a no-op. Guards the
  /// call site so a cleared or unchanged field does not issue a repository
  /// write. Errors propagate through `update(_:)`, which captures them on
  /// `self.error` and rethrows.
  @discardableResult
  func rename(id: UUID, to newName: String) async throws -> Account? {
    let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let account = accounts.by(id: id) else { return nil }
    guard !trimmed.isEmpty, trimmed != account.name else { return account }
    var updated = account
    updated.name = trimmed
    return try await update(updated)
  }

  /// Persists a new ordering. Each underlying `update` is awaited
  /// sequentially; the first error is captured and surfaced. The
  /// reactive observation delivers the authoritative ordering once the
  /// writes commit, so no optimistic mutation is performed here.
  func reorderAccounts(_ reordered: [Account], positionOffset: Int = 0) async {
    setError(nil)

    var firstError: (any Error)?
    for (index, account) in reordered.enumerated() {
      var updated = account
      updated.position = positionOffset + index
      do {
        _ = try await mutationRepository.update(updated)
      } catch {
        mutationLogger.error(
          "Failed to persist account reorder for \(updated.id): \(error)")
        if firstError == nil { firstError = error }
      }
    }

    if let firstError {
      setError(firstError)
    }
  }

  /// Pass-through delete.
  func delete(id: UUID) async throws {
    setError(nil)
    do {
      try await mutationRepository.delete(id: id)
      mutationLogger.debug("Deleted account: \(id)")
    } catch {
      mutationLogger.error("Failed to delete account: \(error.localizedDescription)")
      setError(error)
      throw error
    }
  }
}

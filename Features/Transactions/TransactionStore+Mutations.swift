import Foundation

// Mutation surface for `TransactionStore`.
//
// Mutations are pass-through under the reactive design: every method
// calls the repository, the GRDB write commits, and
// `repository.observe(...)` delivers the authoritative state via the
// view-owned subscription spawned in `observe(filter:)` (or via the rate
// tick observation owned by `init` for converted-balance recomputes).
// There is no optimistic insert / rollback path — the reactive emission
// IS the state update.
extension TransactionStore {

  /// Outcome of `payScheduledTransaction(_:)`. `paid` carries the
  /// rescheduled occurrence (or `nil` when the series ended); the
  /// view maps this to its local selection.
  enum PayResult {
    case paid(updatedScheduledTransaction: Transaction?)
    case deleted
    case failed
  }

  /// Creates a blank expense bound to `accountId` (falling back to
  /// `fallbackAccountId`). See `Transaction.defaultExpense(...)` for the shape.
  func createDefault(
    accountId: UUID?,
    fallbackAccountId: UUID?,
    instrument: Instrument
  ) async -> Transaction? {
    guard let acctId = accountId ?? fallbackAccountId else { return nil }
    return await create(.defaultExpense(accountId: acctId, instrument: instrument))
  }

  /// Creates a blank scheduled expense that does not repeat. See
  /// `Transaction.defaultScheduled(...)`.
  func createDefaultScheduled(
    accountId: UUID?,
    fallbackAccountId: UUID?,
    instrument: Instrument
  ) async -> Transaction? {
    guard let acctId = accountId ?? fallbackAccountId else { return nil }
    return await create(.defaultScheduled(accountId: acctId, instrument: instrument))
  }

  /// Creates a blank earmark-only income transaction. See
  /// `Transaction.defaultEarmarkIncome(...)`.
  func createDefaultEarmark(
    earmarkId: UUID,
    instrument: Instrument
  ) async -> Transaction? {
    await create(.defaultEarmarkIncome(earmarkId: earmarkId, instrument: instrument))
  }

  /// Pass-through create. The reactive observation delivers the new
  /// transaction shortly after the GRDB write commits; no optimistic
  /// insert is needed and there is nothing to roll back because no local
  /// state was mutated. Errors surface on `self.error` and the call
  /// returns `nil`.
  @discardableResult
  func create(_ transaction: Transaction) async -> Transaction? {
    setError(nil)
    do {
      let created = try await repository.create(transaction)
      logger.debug("Created transaction: \(created.id)")
      return created
    } catch {
      logger.error("Failed to create transaction: \(error.localizedDescription)")
      setError(error)
      return nil
    }
  }

  /// Pass-through update.
  func update(_ transaction: Transaction) async {
    setError(nil)
    do {
      _ = try await repository.update(transaction)
      logger.debug("Updated transaction: \(transaction.id)")
    } catch {
      logger.error("Failed to update transaction: \(error.localizedDescription)")
      setError(error)
    }
  }

  /// Pass-through delete.
  func delete(id: UUID) async {
    setError(nil)
    do {
      try await repository.delete(id: id)
      logger.debug("Deleted transaction: \(id)")
    } catch {
      logger.error("Failed to delete transaction: \(error.localizedDescription)")
      setError(error)
    }
  }

  /// Records a payment of `scheduledTransaction`: creates a paid copy dated
  /// today, then either advances the scheduled template to its next due date
  /// (recurring) or deletes it (one-time). Multi-step orchestration that
  /// stays as an imperative store method (per the thin-view rule from
  /// `CLAUDE.md`'s "What belongs in a Store").
  func payScheduledTransaction(_ scheduledTransaction: Transaction) async -> PayResult {
    setIsPayingScheduled(true)
    defer { setIsPayingScheduled(false) }

    let paidTransaction = Transaction.paidCopy(of: scheduledTransaction)
    guard await create(paidTransaction) != nil else { return .failed }

    if let advanced = scheduledTransaction.advancingToNextDueDate() {
      await update(advanced)
      // Return `advanced` directly — it's the canonical state the caller
      // (Pay button) needs for the inspector binding. The reactive
      // observation will deliver the same object via `repository.observe`
      // shortly; we don't wait for that emission here so the Pay button
      // returns promptly.
      return .paid(updatedScheduledTransaction: advanced)
    } else {
      await delete(id: scheduledTransaction.id)
      return .deleted
    }
  }

  // MARK: - Debounced Save

  /// Debounces save calls: cancels any pending save, waits
  /// `debounceInterval` (300ms in production), then calls the callback
  /// on the main actor. Returns the spawned task so tests can await
  /// the live (uncancelled) save deterministically; callers in
  /// production fire-and-forget.
  @discardableResult
  func debouncedSave(perform action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    saveTask?.cancel()
    let task = Task { [debounceInterval] in
      try? await Task.sleep(for: debounceInterval)
      guard !Task.isCancelled else { return }
      action()
    }
    saveTask = task
    return task
  }
}

import Foundation

extension AccountStore {
  /// Aggregate display balance for the accounts in `accountIds`,
  /// converted to `target`. Used by the composite detail-view header
  /// (single-account contexts collapse to the per-account balance) and
  /// by `AccountGroupSidebarRow` for the group's aggregate amount slot.
  ///
  /// Returns `nil` for an empty id list (the caller renders an
  /// "unavailable" state for a zero-member group). Throws when any
  /// contributing account's conversion fails — callers treat a thrown
  /// error as "balance unavailable" (per
  /// `feedback_conversion_failure_ux.md` — never partial-sum). For a
  /// single-id list this collapses to the underlying account's
  /// converted total, so the same code path serves single-account
  /// headers.
  func aggregateBalance(
    for accountIds: [UUID], in target: Instrument
  ) async throws -> InstrumentAmount? {
    guard !accountIds.isEmpty else { return nil }
    let resolved = accountIds.compactMap { accounts.by(id: $0) }
    guard resolved.count == accountIds.count else {
      // One or more ids didn't resolve to a current account (transient
      // store-snapshot lag during sync). Treat as "unavailable" rather
      // than silently undercount.
      return nil
    }
    return try await balanceCalculator.totalConverted(
      for: resolved, to: target, using: investmentValueCache)
  }
}

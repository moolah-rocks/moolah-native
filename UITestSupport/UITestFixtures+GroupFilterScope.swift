import Foundation

/// Parses a UUID literal used in a deterministic test seed. File-private
/// mirror of the helper in `UITestFixtures.swift` — kept local so this
/// extension file has no cross-file dependency for parsing its own
/// literals. Crashes with a clear message on a malformed literal; never
/// substitutes a random UUID (which would make failure artefacts
/// non-diffable).
private func uuidLiteral(_ string: String) -> UUID {
  guard let uuid = UUID(uuidString: string) else {
    fatalError("Malformed UUID literal in test seed: \(string)")
  }
  return uuid
}

extension UITestFixtures {
  /// Fixtures for the `.groupFilterScope` seed.
  ///
  /// Entities (all UUIDs fixed / deterministic; transaction dates are
  /// anchored relative to launch time — see below):
  ///   - Profile `personal` — label "Personal", currency AUD.
  ///   - Account group `filterGroup` ("Filter Group"), `current` bucket.
  ///   - Member accounts `memberOne` ("Member One") and `memberTwo`
  ///     ("Member Two"): both bank / AUD, both pointing at `filterGroup`
  ///     via `account.group_id`.
  ///   - Non-member account `outsider` ("Outsider"): bank / AUD, no group.
  ///   - One single-leg expense (50.00 AUD) in each of the three accounts:
  ///     `memberOneTxn`, `memberTwoTxn`, `outsiderTxn`.
  ///
  /// **Why the dates are wall-clock-relative.** The filter dialog's
  /// "Filter by Date" toggle seeds a default range of `[now − 1 month,
  /// now]`. For the toggle to match every seeded transaction regardless of
  /// when the suite runs, each expense is dated a fixed number of days
  /// before launch (`memberOne*DaysAgo`), all comfortably inside that
  /// one-month window. Only the dates float; every UUID, name, and amount
  /// is constant — mirroring the `importedAt` treatment in the
  /// `.transferDetectionBaseline` seed.
  ///
  /// **The scenario under test.** Selecting `filterGroup` in the sidebar
  /// scopes the transaction list to its two members. Applying a date
  /// filter (which covers all three expenses) must keep the list scoped to
  /// the two members — `outsiderTxn` must never appear. Narrowing the
  /// account picker to `memberOne` must leave only `memberOneTxn`.
  public enum GroupFilterScope {
    public static let profileId = uuidLiteral("A5000000-0000-0000-0000-000000000001")
    public static let profileLabel = "Personal"
    public static let profileCurrencyCode = "AUD"

    public static let filterGroupId = uuidLiteral("A5000000-0000-0000-0000-000000000100")
    public static let filterGroupName = "Filter Group"

    public static let memberOneId = uuidLiteral("A5000000-0000-0000-0000-000000000010")
    public static let memberOneName = "Member One"
    public static let memberTwoId = uuidLiteral("A5000000-0000-0000-0000-000000000011")
    public static let memberTwoName = "Member Two"

    public static let outsiderId = uuidLiteral("A5000000-0000-0000-0000-000000000012")
    public static let outsiderName = "Outsider"

    public static let memberOneTxnId = uuidLiteral("A5000000-0000-0000-0000-000000000020")
    public static let memberOneTxnPayee = "Member One Expense"
    public static let memberTwoTxnId = uuidLiteral("A5000000-0000-0000-0000-000000000021")
    public static let memberTwoTxnPayee = "Member Two Expense"
    public static let outsiderTxnId = uuidLiteral("A5000000-0000-0000-0000-000000000022")
    public static let outsiderTxnPayee = "Outsider Expense"

    /// Cents moved by every seeded expense. Identical across the three so
    /// the test never has to encode amounts — it asserts only on which
    /// transaction rows are present.
    public static let expenseAmountCents = 5_000  // 50.00 AUD

    /// Days-before-launch each expense is dated. All inside the filter
    /// dialog's default `[now − 1 month, now]` window so enabling the date
    /// filter matches every seeded transaction.
    public static let memberOneTxnDaysAgo = 2
    public static let memberTwoTxnDaysAgo = 5
    public static let outsiderTxnDaysAgo = 8
  }
}

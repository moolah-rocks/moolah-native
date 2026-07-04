import XCTest

/// Regression coverage for the group-filter scope bug: applying any filter
/// while viewing an account group must keep the transaction list scoped to
/// the group's members and never surface a non-member account's
/// transactions.
///
/// Seed: `.groupFilterScope` — a "Filter Group" holding "Member One" and
/// "Member Two", plus a standalone "Outsider" account, each carrying one
/// dated expense inside the filter dialog's default date window. See
/// `UITestFixtures.GroupFilterScope`.
@MainActor
final class GroupTransactionFilterScopeMacTests: MoolahUITestCase {

  func testApplyingDateFilterKeepsGroupScope() throws {
    let app = launch(seed: .groupFilterScope)
    app.sidebar.openGroup(.filterGroup)

    let list = app.transactionList
    let fixtures = UITestFixtures.GroupFilterScope.self

    // Group scope before filtering: both members visible, outsider absent.
    list.expectTransactionVisible(fixtures.memberOneTxnId)
    list.expectTransactionVisible(fixtures.memberTwoTxnId)
    list.expectTransactionAbsent(fixtures.outsiderTxnId)

    // Enable the date range (covers all three expenses) and apply.
    let filter = list.openFilter()
    filter.toggleDateFilter(on: true)
    filter.apply()

    // Scope preserved: still exactly the two members, outsider still absent.
    list.expectTransactionVisible(fixtures.memberOneTxnId)
    list.expectTransactionVisible(fixtures.memberTwoTxnId)
    list.expectTransactionAbsent(fixtures.outsiderTxnId)
  }

  func testNarrowingToOneMemberShowsOnlyThatMember() throws {
    let app = launch(seed: .groupFilterScope)
    app.sidebar.openGroup(.filterGroup)

    let list = app.transactionList
    let fixtures = UITestFixtures.GroupFilterScope.self

    // Both members visible in group scope before narrowing.
    list.expectTransactionVisible(fixtures.memberOneTxnId)
    list.expectTransactionVisible(fixtures.memberTwoTxnId)

    // Narrow the account multi-select to Member One, then apply.
    let filter = list.openFilter()
    filter.selectAccount(fixtures.memberOneId)
    filter.apply()

    // Only Member One's transaction remains.
    list.expectTransactionVisible(fixtures.memberOneTxnId)
    list.expectTransactionAbsent(fixtures.memberTwoTxnId)
    list.expectTransactionAbsent(fixtures.outsiderTxnId)
  }
}

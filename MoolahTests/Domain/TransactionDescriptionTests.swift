import Foundation
import Testing

@testable import Moolah

/// Pins the existing perspective-driven description renderings before
/// Phase 6's parameter rename, and adds the new group-view behaviour
/// (per-row context derived from `AccountViewContext.accountIds`).
///
/// The rule under test (spec §"Description rendering & internal
/// transfers"): a single rendering function takes `accountContext:
/// UUID?` — non-nil renders from that account's perspective ("Transfer
/// to/from <other>"); nil renders no-context ("Transfer from <a> to
/// <b>"). The caller derives the per-row context from the view's
/// `accountIds` set: exactly one in-scope leg → that leg's account;
/// otherwise → nil.
@Suite("TransactionDescription")
struct TransactionDescriptionTests {
  // MARK: - Fixtures

  private struct Fixture {
    let accountA: Account
    let accountB: Account
    let accountC: Account
    let accounts: Accounts
    let earmarks: Earmarks

    init() {
      accountA = Account(
        id: UUID(), name: "Checking", type: .bank, instrument: .AUD)
      accountB = Account(
        id: UUID(), name: "Savings", type: .bank, instrument: .AUD)
      accountC = Account(
        id: UUID(), name: "Crypto Wallet", type: .crypto, instrument: .AUD)
      accounts = Accounts(from: [accountA, accountB, accountC])
      earmarks = Earmarks(from: [])
    }
  }

  private func makeTransfer(
    from source: Account, to destination: Account, payee: String? = nil
  ) -> Transaction {
    Transaction(
      date: Date(),
      payee: payee,
      legs: [
        TransactionLeg(
          accountId: source.id, instrument: source.instrument,
          quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: destination.id, instrument: destination.instrument,
          quantity: 100, type: .transfer),
      ])
  }

  private func makeExpense(on account: Account, payee: String) -> Transaction {
    Transaction(
      date: Date(),
      payee: payee,
      legs: [
        TransactionLeg(
          accountId: account.id, instrument: account.instrument,
          quantity: -25, type: .expense)
      ])
  }

  // MARK: - Single-leg expenses

  @Test
  func simpleExpenseRendersPayeeUnchangedAcrossPerspectives() {
    let fixture = Fixture()
    let transaction = makeExpense(on: fixture.accountA, payee: "Coffee Shop")

    // Single-account view (perspective set).
    let withContext = transaction.displayPayee(
      accountContext: fixture.accountA.id,
      accounts: fixture.accounts, earmarks: fixture.earmarks)
    #expect(withContext == "Coffee Shop")

    // No-context view (scheduled / all transactions).
    let noContext = transaction.displayPayee(
      accountContext: nil,
      accounts: fixture.accounts, earmarks: fixture.earmarks)
    #expect(noContext == "Coffee Shop")
  }

  // MARK: - Two-leg transfers (perspective set)

  @Test
  func transferFromPerspectiveOfSourceRendersTransferTo() {
    let fixture = Fixture()
    let transaction = makeTransfer(from: fixture.accountA, to: fixture.accountB)

    let description = transaction.displayPayee(
      accountContext: fixture.accountA.id,
      accounts: fixture.accounts, earmarks: fixture.earmarks)
    #expect(description == "Transfer to Savings")
  }

  @Test
  func transferFromPerspectiveOfDestinationRendersTransferFrom() {
    let fixture = Fixture()
    let transaction = makeTransfer(from: fixture.accountA, to: fixture.accountB)

    let description = transaction.displayPayee(
      accountContext: fixture.accountB.id,
      accounts: fixture.accounts, earmarks: fixture.earmarks)
    #expect(description == "Transfer from Checking")
  }

  @Test
  func transferWithPayeeWrapsTransferLabelInParentheses() {
    let fixture = Fixture()
    let transaction = makeTransfer(
      from: fixture.accountA, to: fixture.accountB, payee: "Loan Payment")

    let description = transaction.displayPayee(
      accountContext: fixture.accountA.id,
      accounts: fixture.accounts, earmarks: fixture.earmarks)
    #expect(description == "Loan Payment (Transfer to Savings)")
  }

  // MARK: - Two-leg transfers (no perspective)

  @Test
  func transferWithoutPerspectiveRendersFromToBothAccounts() {
    let fixture = Fixture()
    let transaction = makeTransfer(from: fixture.accountA, to: fixture.accountB)

    let description = transaction.displayPayee(
      accountContext: nil,
      accounts: fixture.accounts, earmarks: fixture.earmarks)
    #expect(description == "Transfer from Checking to Savings")
  }

  // MARK: - Group view (single in-scope leg → member perspective)

  @Test
  func groupViewSingleInScopeLegRendersFromMemberPerspective() {
    let fixture = Fixture()
    // Group context = {accountA, accountC}. Transfer touches accountA + accountB,
    // so exactly one in-scope leg (accountA). Description should phrase from
    // accountA's perspective.
    let transaction = makeTransfer(from: fixture.accountA, to: fixture.accountB)
    let groupMemberIds: Set<UUID> = [fixture.accountA.id, fixture.accountC.id]

    let inScope = transaction.legs
      .compactMap(\.accountId)
      .filter { groupMemberIds.contains($0) }
    let context: UUID? = inScope.count == 1 ? inScope.first : nil
    #expect(context == fixture.accountA.id)

    let description = transaction.displayPayee(
      accountContext: context,
      accounts: fixture.accounts, earmarks: fixture.earmarks)
    #expect(description == "Transfer to Savings")
  }

  // MARK: - Group view (multiple in-scope legs → no-context phrasing)

  @Test
  func groupViewMultipleInScopeLegsRendersNoContext() {
    let fixture = Fixture()
    // Group context = {accountA, accountB} — an intra-group transfer.
    // Both legs are in scope → no single perspective → no-context style.
    let transaction = makeTransfer(from: fixture.accountA, to: fixture.accountB)
    let groupMemberIds: Set<UUID> = [fixture.accountA.id, fixture.accountB.id]

    let inScope = transaction.legs
      .compactMap(\.accountId)
      .filter { groupMemberIds.contains($0) }
    let context: UUID? = inScope.count == 1 ? inScope.first : nil
    #expect(context == nil)

    let description = transaction.displayPayee(
      accountContext: context,
      accounts: fixture.accounts, earmarks: fixture.earmarks)
    #expect(description == "Transfer from Checking to Savings")
  }

  // MARK: - All-accounts view (multi-leg always no-context)

  @Test
  func allAccountsViewMultiLegTransactionAlwaysNoContext() {
    let fixture = Fixture()
    // All-accounts view: in-scope set contains every account, so both legs
    // are in scope → context = nil → no-context rendering. Matches today.
    let transaction = makeTransfer(from: fixture.accountA, to: fixture.accountB)
    let allIds: Set<UUID> = [
      fixture.accountA.id, fixture.accountB.id, fixture.accountC.id,
    ]

    let inScope = transaction.legs
      .compactMap(\.accountId)
      .filter { allIds.contains($0) }
    let context: UUID? = inScope.count == 1 ? inScope.first : nil
    #expect(context == nil)

    let description = transaction.displayPayee(
      accountContext: context,
      accounts: fixture.accounts, earmarks: fixture.earmarks)
    #expect(description == "Transfer from Checking to Savings")
  }
}

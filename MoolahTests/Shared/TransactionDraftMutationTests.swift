import Foundation
import Testing

@testable import Moolah

// Swift Testing's `@Test func foo()` is the documented idiom, and
// swift-format's `lineBreakBetweenDeclarationAttributes: false` keeps the
// attribute inline. Disable SwiftLint's `attributes` rule in this file so
// the formatter and the linter don't fight over the same layout.
// swiftlint:disable attributes

@Suite("TransactionDraft setType / setAmount / mode switching")
struct TransactionDraftMutationTests {
  private let support = TransactionDraftTestSupport()

  // MARK: - setType

  @Test func setTypeExpenseToIncome() {
    var draft = support.makeExpenseDraft(amountText: "50.00")
    draft.setType(
      .income, accounts: support.makeAccounts([support.makeAccount(id: support.accountA)]))

    #expect(draft.legDrafts.count == 1)
    #expect(draft.legDrafts[0].type == .income)
    // Display text stays the same
    #expect(draft.legDrafts[0].amountText == "50.00")
  }

  @Test func setTypeExpenseToTransfer() {
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA),
      support.makeAccount(id: support.accountB),
    ])
    var draft = support.makeExpenseDraft(amountText: "50.00", accountId: support.accountA)
    draft.setType(.transfer, accounts: accounts)

    #expect(draft.legDrafts.count == 2)
    #expect(draft.legDrafts[0].type == .transfer)
    #expect(draft.legDrafts[0].amountText == "50.00")
    // Counterpart added with negated display amount and default account
    #expect(draft.legDrafts[1].type == .transfer)
    #expect(draft.legDrafts[1].amountText == "-50.00")
    #expect(draft.legDrafts[1].accountId == support.accountB)
  }

  @Test func setTypeTransferToExpense() {
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA),
      support.makeAccount(id: support.accountB),
    ])
    var draft = support.makeExpenseDraft(amountText: "50.00", accountId: support.accountA)
    draft.setType(.transfer, accounts: accounts)
    // Now switch back to expense
    draft.setType(.expense, accounts: accounts)

    #expect(draft.legDrafts.count == 1)
    #expect(draft.legDrafts[0].type == .expense)
    #expect(draft.legDrafts[0].amountText == "50.00")
  }

  @Test func setTypeIncomeToTransfer() {
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA),
      support.makeAccount(id: support.accountB),
    ])
    var draft = TransactionDraft(
      payee: "Test", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .income, accountId: support.accountA, amountText: "50.00",
          categoryId: nil, categoryText: "", earmarkId: nil)
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    draft.setType(.transfer, accounts: accounts)

    #expect(draft.legDrafts.count == 2)
    #expect(draft.legDrafts[0].type == .transfer)
    #expect(draft.legDrafts[0].amountText == "50.00")
    #expect(draft.legDrafts[1].amountText == "-50.00")
  }

  @Test func setTypeTransferDefaultAccountExcludesCurrentAccount() {
    let accountC = UUID()
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA),
      support.makeAccount(id: support.accountB),
      support.makeAccount(id: accountC),
    ])
    var draft = support.makeExpenseDraft(amountText: "50.00", accountId: support.accountA)
    draft.setType(.transfer, accounts: accounts)

    // Counterpart should not be accountA
    #expect(draft.legDrafts[1].accountId != support.accountA)
  }

  @Test func setTypeClearsCounterpartCategoryAndEarmark() {
    let categoryId = UUID()
    let earmarkId = UUID()
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA),
      support.makeAccount(id: support.accountB),
    ])
    var draft = TransactionDraft(
      payee: "Test", date: Date(), notes: "",
      isRepeating: false, recurPeriod: nil, recurEvery: 1,
      isCustom: false,
      legDrafts: [
        TransactionDraft.LegDraft(
          type: .expense, accountId: support.accountA, amountText: "50.00",
          categoryId: categoryId, categoryText: "Food", earmarkId: earmarkId)
      ],
      relevantLegIndex: 0, viewingAccountId: nil
    )
    draft.setType(.transfer, accounts: accounts)

    // Primary leg (0) keeps category/earmark
    #expect(draft.legDrafts[0].categoryId == categoryId)
    #expect(draft.legDrafts[0].earmarkId == earmarkId)
    // Counterpart has nil
    #expect(draft.legDrafts[1].categoryId == nil)
    #expect(draft.legDrafts[1].earmarkId == nil)
  }

  // MARK: - setAmount

  @Test func setAmountSimpleExpense() {
    var draft = support.makeExpenseDraft(amountText: "10.00")
    draft.setAmount("75.00")
    #expect(draft.legDrafts[0].amountText == "75.00")
  }

  @Test func setAmountSimpleTransferMirrorsToCounterpart() {
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA),
      support.makeAccount(id: support.accountB),
    ])
    var draft = support.makeExpenseDraft(amountText: "50.00", accountId: support.accountA)
    draft.setType(.transfer, accounts: accounts)

    draft.setAmount("75.00")
    #expect(draft.legDrafts[draft.relevantLegIndex].amountText == "75.00")
    // Counterpart gets parse-negate-format
    let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
    #expect(draft.legDrafts[counterIdx].amountText == "-75.00")
  }

  @Test func setAmountNegativeDisplayMirrorsPositiveToCounterpart() {
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA),
      support.makeAccount(id: support.accountB),
    ])
    var draft = support.makeExpenseDraft(amountText: "50.00", accountId: support.accountA)
    draft.setType(.transfer, accounts: accounts)

    // Negative display value (reversed transfer)
    draft.setAmount("-10.00")
    #expect(draft.legDrafts[draft.relevantLegIndex].amountText == "-10.00")
    let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
    #expect(draft.legDrafts[counterIdx].amountText == "10.00")
  }

  @Test func setAmountUnparseableCascadesToInvalidCounterpart() {
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA),
      support.makeAccount(id: support.accountB),
    ])
    var draft = support.makeExpenseDraft(amountText: "50.00", accountId: support.accountA)
    draft.setType(.transfer, accounts: accounts)

    draft.setAmount("abc")
    #expect(draft.legDrafts[draft.relevantLegIndex].amountText == "abc")
    let counterIdx = draft.relevantLegIndex == 0 ? 1 : 0
    #expect(draft.legDrafts[counterIdx].amountText.isEmpty)
  }

  @Test func setAmountZeroIsValid() {
    var draft = support.makeExpenseDraft(amountText: "10.00")
    draft.setAmount("0")
    #expect(draft.legDrafts[0].amountText == "0")
  }

  @Test func setAmountFromDestinationPerspectiveMirrorsCorrectly() {
    // Transfer where relevant leg is index 1 (viewing from destination)
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: 100, type: .transfer),
      ]
    )
    var draft = TransactionDraft(from: transaction, viewingAccountId: support.accountB)
    #expect(draft.relevantLegIndex == 1)

    // User changes amount to 200 (from their perspective)
    draft.setAmount("200.00")
    #expect(draft.legDrafts[1].amountText == "200.00")
    // Primary leg (index 0) gets negated
    #expect(draft.legDrafts[0].amountText == "-200.00")
  }

  // MARK: - Relevant Leg Stability

  @Test func relevantLegStableWhenAmountSignChanges() {
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: 100, type: .transfer),
      ]
    )
    var draft = TransactionDraft(from: transaction, viewingAccountId: support.accountA)
    let originalIndex = draft.relevantLegIndex

    // Change amount to negative (would flip which leg is "outflow")
    draft.setAmount("-50.00")

    // Relevant leg index must NOT change
    #expect(draft.relevantLegIndex == originalIndex)
    #expect(draft.legDrafts[originalIndex].accountId == support.accountA)
  }

  // MARK: - Mode Switching

  @Test func switchToCustomPreservesLegs() {
    var draft = support.makeExpenseDraft(amountText: "50.00", accountId: support.accountA)
    draft.isCustom = true
    #expect(draft.legDrafts.count == 1)
    #expect(draft.legDrafts[0].amountText == "50.00")
  }

  @Test func switchToSimpleRepinsRelevantLeg() {
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: 100, type: .transfer),
      ]
    )
    var draft = TransactionDraft(from: transaction, viewingAccountId: support.accountB)
    draft.isCustom = true
    // Switch back to simple
    draft.switchToSimple()
    #expect(draft.isCustom == false)
    #expect(draft.relevantLegIndex == 1)  // re-pinned to accountB
  }

  @Test func switchToSimpleNoContextPinsToZero() {
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: 100, type: .transfer),
      ]
    )
    var draft = TransactionDraft(from: transaction)
    draft.isCustom = true
    draft.switchToSimple()
    #expect(draft.relevantLegIndex == 0)
  }

  @Test func canSwitchToSimpleWhenLegsAreSimple() {
    var draft = support.makeExpenseDraft()
    draft.isCustom = true
    #expect(draft.canSwitchToSimple == true)
  }

  @Test func cannotSwitchToSimpleWithoutLegs() {
    let transaction = Transaction(date: Date(), legs: [])
    let draft = TransactionDraft(from: transaction)
    #expect(draft.canSwitchToSimple == false)
  }

  @Test func cannotSwitchToSimpleWithThreeLegs() {
    var draft = support.makeExpenseDraft()
    draft.isCustom = true
    draft.legDrafts.append(
      TransactionDraft.LegDraft(
        type: .expense, accountId: support.accountB, amountText: "5.00",
        categoryId: nil, categoryText: "", earmarkId: nil))
    draft.legDrafts.append(
      TransactionDraft.LegDraft(
        type: .income, accountId: UUID(), amountText: "15.00",
        categoryId: nil, categoryText: "", earmarkId: nil))
    #expect(draft.canSwitchToSimple == false)
  }
}

// swiftlint:enable attributes

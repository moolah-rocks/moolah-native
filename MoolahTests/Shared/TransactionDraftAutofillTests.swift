import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft autofill from matching transaction")
struct TransactionDraftAutofillTests {
  private let support = TransactionDraftTestSupport()

  @Test
  func autofillCopiesEverythingExceptDate() throws {
    let categoryId = UUID()
    let earmarkId = UUID()
    let matchDate = Date(timeIntervalSince1970: 999_999)
    let quantity = try #require(Decimal(string: "-5.50"))
    let matchTx = Transaction(
      date: matchDate,
      payee: "Coffee",
      notes: "Morning",
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: quantity, type: .expense,
          categoryId: categoryId, earmarkId: earmarkId)
      ]
    )

    let originalDate = Date()
    var draft = TransactionDraft(accountId: support.accountA, viewingAccountId: support.accountA)
    draft.date = originalDate

    draft.applyAutofill(from: matchTx, categories: Categories(from: []))

    #expect(draft.payee == "Coffee")
    #expect(draft.notes == "Morning")
    #expect(draft.legDrafts[0].type == .expense)
    #expect(draft.legDrafts[0].amountText == "5.50")
    #expect(draft.legDrafts[0].accountId == support.accountA)
    #expect(draft.legDrafts[0].categoryId == categoryId)
    #expect(draft.legDrafts[0].earmarkId == earmarkId)
    // Date preserved from original draft
    #expect(draft.date == originalDate)
    #expect(draft.date != matchDate)
  }

  /// Autofill creates a *new* transaction from a template. If the template is
  /// a wallet-imported transaction, the new manual transaction must NOT inherit
  /// the template's on-chain identity (`externalId` / `counterpartyAddress`) —
  /// doing so would pollute the importer's `(accountId, externalId)` dedup key
  /// and could suppress a genuine future import of that on-chain event.
  @Test
  func autofillDoesNotCarryOnChainIdentityFromMatch() {
    let matchTx = Transaction(
      date: Date(),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -5, externalId: "0xdeadbeef:erc20:0",
          counterpartyAddress: "0xcounterparty", type: .expense)
      ]
    )

    var draft = TransactionDraft(accountId: support.accountA, viewingAccountId: support.accountA)
    draft.applyAutofill(from: matchTx, categories: Categories(from: []))

    #expect(draft.legDrafts[0].externalId == nil)
    #expect(draft.legDrafts[0].counterpartyAddress == nil)
  }

  @Test
  func autofillFromComplexTransactionSetsCustomMode() {
    let matchTx = Transaction(
      date: Date(),
      payee: "Split",
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -100, type: .expense),
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: -50, type: .expense),
        TransactionLeg(
          accountId: UUID(), instrument: support.instrument,
          quantity: 150, type: .income),
      ]
    )

    var draft = TransactionDraft(accountId: support.accountA, viewingAccountId: support.accountA)
    draft.applyAutofill(from: matchTx, categories: Categories(from: []))

    #expect(draft.isCustom == true)
    #expect(draft.legDrafts.count == 3)
    #expect(draft.payee == "Split")
  }

  @Test
  func autofillPopulatesCategoryText() {
    let categoryId = UUID()
    let matchTx = Transaction(
      date: Date(),
      payee: "Shop",
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -10, type: .expense, categoryId: categoryId)
      ]
    )
    let categories = Categories(from: [Category(id: categoryId, name: "Groceries")])

    var draft = TransactionDraft(accountId: support.accountA, viewingAccountId: support.accountA)
    draft.applyAutofill(from: matchTx, categories: categories)

    #expect(draft.legDrafts[0].categoryId == categoryId)
    #expect(draft.legDrafts[0].categoryText == "Groceries")
  }

  @Test
  func autofillPreservesViewingAccountForSimpleMatch() {
    // Match was recorded against accountB, but the user is viewing accountA.
    let matchTx = Transaction(
      date: Date(),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: -5, type: .expense)
      ]
    )

    var draft = TransactionDraft(accountId: support.accountA, viewingAccountId: support.accountA)
    draft.applyAutofill(from: matchTx, categories: Categories(from: []))

    // The leg's account must remain the viewed account; only the other
    // fields (amount, type, category, etc.) should be copied from the match.
    #expect(draft.legDrafts[0].accountId == support.accountA)
  }

  @Test
  func autofillRemapsInstrumentToViewingAccount() {
    let usd = Instrument.fiat(code: "USD")
    let eur = Instrument.fiat(code: "EUR")
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA, instrument: usd),
      support.makeAccount(id: support.accountB, instrument: eur),
    ])
    let matchTx = Transaction(
      date: Date(),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: support.accountB, instrument: eur,
          quantity: -5, type: .expense)
      ]
    )

    var draft = TransactionDraft(accountId: support.accountA, viewingAccountId: support.accountA)
    draft.applyAutofill(from: matchTx, categories: Categories(from: []), accounts: accounts)

    #expect(draft.legDrafts[0].accountId == support.accountA)
    #expect(draft.legDrafts[0].instrument == usd)
  }

  @Test
  func autofillWithoutViewingContextUsesMatchAccount() {
    // When there's no viewing account (e.g. "All Transactions"), autofill
    // should adopt the match's account as before.
    let matchTx = Transaction(
      date: Date(),
      payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: -5, type: .expense)
      ]
    )

    var draft = TransactionDraft(accountId: support.accountA, viewingAccountId: nil)
    draft.applyAutofill(from: matchTx, categories: Categories(from: []))

    #expect(draft.legDrafts[0].accountId == support.accountB)
  }

  @Test
  func autofillPreservesViewingAccountForTransferMatch() {
    // Transfer match is A->B, but user is viewing accountC; the viewed-account
    // leg should be remapped to C while the counterpart leg is preserved.
    let accountC = UUID()
    let matchTx = Transaction(
      date: Date(),
      payee: "Savings",
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -100, type: .transfer),
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: 100, type: .transfer),
      ]
    )

    var draft = TransactionDraft(accountId: accountC, viewingAccountId: accountC)
    draft.applyAutofill(from: matchTx, categories: Categories(from: []))

    // pinRelevantLeg falls through to index 0 since C isn't in the match, so
    // leg 0 is the "viewed" leg and must be remapped to accountC.
    #expect(draft.legDrafts[0].accountId == accountC)
    #expect(draft.legDrafts[1].accountId == support.accountB)
  }
}

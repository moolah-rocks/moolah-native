import Foundation
import Testing

@testable import Moolah

@Suite("TransactionDraft preserves leg ids end-to-end")
struct TransactionDraftLegIdTests {

  @Test("init(from:) populates legId from each source leg")
  func initFromTransactionPopulatesLegId() {
    let leg = TransactionLeg(
      accountId: UUID(),
      instrument: Instrument.defaultTestInstrument,
      quantity: Decimal(-10), type: .expense)
    let txn = Transaction(date: Date(), payee: "Coffee", legs: [leg])
    let draft = TransactionDraft(from: txn)
    #expect(draft.legDrafts.first?.legId == leg.id)
  }

  @Test("toTransaction(id:) round-trips legId for legs that came from a transaction")
  func toTransactionRoundTripsLegId() throws {
    let leg = TransactionLeg(
      accountId: UUID(),
      instrument: Instrument.defaultTestInstrument,
      quantity: Decimal(-10), type: .expense)
    let txn = Transaction(date: Date(), payee: "Coffee", legs: [leg])
    let draft = TransactionDraft(from: txn)
    let rebuilt = try #require(draft.toTransaction(id: txn.id))
    #expect(rebuilt.legs.map(\.id) == [leg.id])
  }

  @Test("addLeg leaves the new draft's legId nil; saving allocates a fresh id")
  func addLegAllocatesFreshIdAtSave() throws {
    let leg = TransactionLeg(
      accountId: UUID(),
      instrument: Instrument.defaultTestInstrument,
      quantity: Decimal(-10), type: .expense)
    let txn = Transaction(date: Date(), payee: "Coffee", legs: [leg])
    var draft = TransactionDraft(from: txn)
    // `isCustom` is the precondition for `toTransaction(id:)` to accept
    // a multi-leg non-transfer draft below; without it `isValid` would
    // refuse the second leg and `toTransaction` would return nil.
    draft.isCustom = true
    draft.addLeg(defaultAccountId: leg.accountId, instrument: Instrument.defaultTestInstrument)
    #expect(draft.legDrafts.last?.legId == nil)

    let rebuilt = try #require(draft.toTransaction(id: txn.id))
    #expect(rebuilt.legs.count == 2)
    #expect(rebuilt.legs[0].id == leg.id)
    #expect(rebuilt.legs[1].id != leg.id)
  }

  @Test("applyAutofill never carries the source's leg ids, so saving can't steal its rows")
  func applyAutofillDoesNotReuseSourceLegIds() throws {
    let sourceLeg = TransactionLeg(
      accountId: UUID(),
      instrument: Instrument.defaultTestInstrument,
      quantity: Decimal(-25), type: .expense,
      categoryId: UUID())
    let source = Transaction(
      date: Date(timeIntervalSince1970: 0),
      payee: "Coffee",
      legs: [sourceLeg])

    // A draft with no prior persistence has legId == nil, exercising the
    // fresh-id fallback in autofill. In production a new transaction always
    // opens from a persisted placeholder that already carries a non-nil
    // legId (covered by `applyAutofillReusesOwnLegId`); this is the
    // defensive case.
    var draft = TransactionDraft(accountId: nil, instrument: Instrument.defaultTestInstrument)

    draft.applyAutofill(
      from: source, categories: Categories(from: []), accounts: Accounts(from: []))

    // The carried leg's content matches `source` but it gets an id of its
    // own — never the source's — so the GRDB upsert can't collide with or
    // steal `source.legs[0]`.
    let carriedIds = Set(draft.legDrafts.compactMap(\.legId))
    #expect(!carriedIds.contains(sourceLeg.id))

    let saved = try #require(draft.toTransaction(id: UUID()))
    #expect(saved.legs.first?.id != sourceLeg.id)
  }

  @Test("applyAutofill reuses the draft's own leg id so repeated saves don't churn")
  func applyAutofillReusesOwnLegId() throws {
    // A new transaction always opens from a placeholder that was persisted
    // up front, so its single leg already owns a stable id. Autofill must
    // reuse that id rather than mint a fresh one on every debounced save —
    // leg-id churn is what surfaces as a duplicate leg during sync apply
    // (#872, https://github.com/moolah-rocks/moolah-native/issues/872).
    let placeholderLeg = TransactionLeg(
      accountId: UUID(),
      instrument: Instrument.defaultTestInstrument,
      quantity: .zero, type: .expense)
    let placeholder = Transaction(date: Date(), payee: "", legs: [placeholderLeg])
    var draft = TransactionDraft(from: placeholder)

    let sourceLeg = TransactionLeg(
      accountId: UUID(),
      instrument: Instrument.defaultTestInstrument,
      quantity: Decimal(-25), type: .expense,
      categoryId: UUID())
    let source = Transaction(
      date: Date(timeIntervalSince1970: 0), payee: "Coffee", legs: [sourceLeg])

    draft.applyAutofill(
      from: source, categories: Categories(from: []), accounts: Accounts(from: []))

    // Reuses this transaction's own leg id — not the source's.
    #expect(draft.legDrafts.map(\.legId) == [placeholderLeg.id])
    #expect(placeholderLeg.id != sourceLeg.id)

    // So saving twice yields the same leg id: no per-keystroke leg swap.
    let first = try #require(draft.toTransaction(id: placeholder.id))
    let second = try #require(draft.toTransaction(id: placeholder.id))
    #expect(first.legs.map(\.id) == [placeholderLeg.id])
    #expect(second.legs.map(\.id) == first.legs.map(\.id))
  }

  @Test("applyAutofill gives extra legs from a multi-leg source stable ids")
  func applyAutofillStabilisesExtraLegIds() throws {
    let placeholderLeg = TransactionLeg(
      accountId: UUID(),
      instrument: Instrument.defaultTestInstrument,
      quantity: .zero, type: .expense)
    let placeholder = Transaction(date: Date(), payee: "", legs: [placeholderLeg])
    var draft = TransactionDraft(from: placeholder)

    let legA = TransactionLeg(
      accountId: UUID(), instrument: Instrument.defaultTestInstrument,
      quantity: Decimal(-25), type: .transfer)
    let legB = TransactionLeg(
      accountId: UUID(), instrument: Instrument.defaultTestInstrument,
      quantity: Decimal(25), type: .transfer)
    let source = Transaction(
      date: Date(timeIntervalSince1970: 0), payee: "Rent", legs: [legA, legB])

    draft.applyAutofill(
      from: source, categories: Categories(from: []), accounts: Accounts(from: []))

    // Every carried leg has a stable, non-nil id of its own …
    #expect(draft.legDrafts.allSatisfy { $0.legId != nil })
    // … the first reusing the placeholder's id, none reusing the source's.
    #expect(draft.legDrafts.first?.legId == placeholderLeg.id)
    let carriedIds = Set(draft.legDrafts.compactMap(\.legId))
    #expect(carriedIds.isDisjoint(with: [legA.id, legB.id]))

    // Saving twice is idempotent — identical leg ids, no churn.
    let first = try #require(draft.toTransaction(id: placeholder.id))
    let second = try #require(draft.toTransaction(id: placeholder.id))
    #expect(first.legs.map(\.id) == second.legs.map(\.id))
  }

  @Test("changing the payee re-runs autofill and keeps the same stable leg id")
  func applyAutofillTwiceKeepsSameLegId() throws {
    // The user can pick one payee, then change their mind and pick another.
    // The second autofill reads the already-stable id the first one pinned,
    // so the leg id never drifts — no churn across repeated autofills.
    let placeholderLeg = TransactionLeg(
      accountId: UUID(),
      instrument: Instrument.defaultTestInstrument,
      quantity: .zero, type: .expense)
    let placeholder = Transaction(date: Date(), payee: "", legs: [placeholderLeg])
    var draft = TransactionDraft(from: placeholder)

    let coffee = Transaction(
      date: Date(timeIntervalSince1970: 0), payee: "Coffee",
      legs: [
        TransactionLeg(
          accountId: UUID(), instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-25), type: .expense)
      ])
    draft.applyAutofill(from: coffee, categories: Categories(from: []))
    #expect(draft.legDrafts.map(\.legId) == [placeholderLeg.id])

    let lunch = Transaction(
      date: Date(timeIntervalSince1970: 0), payee: "Lunch",
      legs: [
        TransactionLeg(
          accountId: UUID(), instrument: Instrument.defaultTestInstrument,
          quantity: Decimal(-15), type: .expense)
      ])
    draft.applyAutofill(from: lunch, categories: Categories(from: []))
    #expect(draft.legDrafts.map(\.legId) == [placeholderLeg.id])
  }
}

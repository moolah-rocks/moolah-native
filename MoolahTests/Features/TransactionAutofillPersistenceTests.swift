import Foundation
import Testing

@testable import Moolah

/// End-to-end regression cover for payee-autocomplete autofill: the draft
/// must carry stable leg ids so repeated debounced saves upsert the same
/// rows instead of churning a fresh leg id each time.
@Suite("Payee autofill persists a stable single leg")
@MainActor
struct TransactionAutofillPersistenceTests {

  /// Reload a single transaction by id via `fetchAll`, since
  /// `TransactionRepository` exposes only filter/pagination fetches.
  private func reload(
    _ repo: any TransactionRepository, id: UUID
  ) async throws -> Transaction? {
    let all = try await repo.fetchAll(filter: TransactionFilter())
    return all.first(where: { $0.id == id })
  }

  @Test("autofill then repeated edits keep the placeholder's single leg id stable")
  func autofillThenEditsKeepsSingleStableLeg() async throws {
    // End-to-end repro of #872's residual: a new transaction opens from a
    // persisted placeholder, the user picks a payee (autofill copies a past
    // transaction's leg), then edits the amount. Every debounced save must
    // upsert the *same* leg row. Before the fix, autofill cleared the leg
    // id, so each save minted a fresh UUID — orphaning the placeholder leg
    // and emitting a leg-swap that shows up as a duplicate during sync
    // apply. GRDB deletes the orphan locally, so the tell-tale here is the
    // leg *id* drifting away from the placeholder's, not the leg count.
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank,
        instrument: Instrument.defaultTestInstrument, positions: []))

    // A past "Coffee" transaction to autofill from.
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(timeIntervalSince1970: 0), payee: "Coffee",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: Instrument.defaultTestInstrument,
            quantity: -25, type: .expense)
        ]))

    // The placeholder a new transaction opens from (persisted up front).
    let placeholder = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "",
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: Instrument.defaultTestInstrument,
            quantity: 0, type: .expense)
        ]))
    let placeholderLegId = placeholder.legs[0].id

    // User picks "Coffee" from autocomplete → autofill.
    var draft = TransactionDraft(from: placeholder)
    let match = try #require(
      await backend.transactions.fetchAll(filter: TransactionFilter(payee: "Coffee")).first)
    draft.applyAutofill(
      from: match, categories: Categories(from: []), accounts: Accounts(from: []))

    // First debounced save.
    _ = try await backend.transactions.update(
      try #require(draft.toTransaction(id: placeholder.id)))

    // User edits the amount → second debounced save.
    draft.setAmount("30")
    _ = try await backend.transactions.update(
      try #require(draft.toTransaction(id: placeholder.id)))

    let reloaded = try #require(try await reload(backend.transactions, id: placeholder.id))
    #expect(reloaded.legs.map(\.id) == [placeholderLegId])
  }
}

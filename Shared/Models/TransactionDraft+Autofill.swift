import Foundation

extension TransactionDraft {
  /// Replace this draft with data from a matching transaction, preserving the current date.
  /// Category text is populated from the categories collection.
  ///
  /// When the draft has a `viewingAccountId` (autofill was triggered while the
  /// user was scoped to a specific account list), the relevant leg is pinned to
  /// the viewed account so a past transaction from a different account can't
  /// silently move the new transaction out of the list the user is working in.
  /// Pass `accounts` to also realign the leg's instrument with the viewed
  /// account's instrument.
  mutating func applyAutofill(
    from match: Transaction,
    categories: Categories,
    accounts: Accounts = Accounts(from: [])
  ) {
    let preservedDate = self.date
    let preservedViewingAccountId = self.viewingAccountId

    // Build a fresh draft from the match
    var newDraft = TransactionDraft(
      from: match, viewingAccountId: preservedViewingAccountId, accounts: accounts)
    newDraft.date = preservedDate

    // Populate category text for all legs
    for i in newDraft.legDrafts.indices {
      if let catId = newDraft.legDrafts[i].categoryId,
        let cat = categories.by(id: catId)
      {
        newDraft.legDrafts[i].categoryText = categories.path(for: cat)
      }
    }

    // Autofill copies content from a *different* transaction, but the legs
    // save into *this* one. Each carried leg therefore takes a stable id of
    // this transaction's own — never the source's, which would PK-collide
    // with (and steal) the source's rows on the GRDB upsert. Ids come from
    // this draft's existing legs, matched positionally: a new transaction
    // always opens from a persisted placeholder that already owns one, so
    // every debounced save upserts the same row rather than inserting a new
    // one. Any extra leg a multi-leg source brings in gets a fresh id minted
    // once here, so it too stays stable across saves (#872).
    let ownLegIds = self.legDrafts.map(\.legId)
    newDraft.legDrafts = newDraft.legDrafts.enumerated().map { index, leg in
      let stableId = (index < ownLegIds.count ? ownLegIds[index] : nil) ?? UUID()
      return leg.withLegId(stableId)
    }

    // Preserve the viewed account. Skip custom mode: a complex match has no
    // single "viewed" leg, and adopting its structure means the user is
    // already accepting whatever accounts it references.
    if let viewingId = preservedViewingAccountId, !newDraft.isCustom {
      let idx = newDraft.relevantLegIndex
      if newDraft.legDrafts[idx].accountId != viewingId {
        newDraft.legDrafts[idx].accountId = viewingId
        if let viewedAccount = accounts.by(id: viewingId) {
          newDraft.legDrafts[idx].instrument = viewedAccount.instrument
        }
      }
    }

    self = newDraft
  }
}

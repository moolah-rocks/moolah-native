import Foundation

struct EditAccountDraft: Equatable, Sendable {
  var name: String
  var type: AccountType
  var instrument: Instrument
  var isHidden: Bool
  var taxOwnerIds: [UUID]

  func applied(to account: Account) -> Account {
    var updated = account
    updated.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    updated.type = type
    updated.instrument = instrument
    updated.isHidden = isHidden
    updated.valuationMode = .calculatedFromTrades
    updated.taxOwnerIds = taxOwnerIds
    return updated
  }
}

extension EditAccountView {
  static func updatedAccount(
    from account: Account,
    draft: EditAccountDraft,
    validOwners: [TaxOwner] = []
  ) -> Account {
    var normalizedDraft = draft
    normalizedDraft.taxOwnerIds = TaxOwnerAssignmentState.prunedSelectedOwnerIds(
      draft.taxOwnerIds, validOwners: validOwners)
    return normalizedDraft.applied(to: account)
  }
}

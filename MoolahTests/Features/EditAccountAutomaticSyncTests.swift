import Testing

@testable import Moolah

@Suite("Edit account automatic sync")
struct EditAccountAutomaticSyncTests {
  @Test("Saving the toggle disables automatic sync")
  func savingToggleDisablesAutomaticSync() {
    let account = Account(
      name: "Coinstash",
      type: .exchange,
      instrument: .AUD,
      exchangeProvider: .coinstash)
    let draft = EditAccountDraft(
      name: account.name,
      type: account.type,
      instrument: account.instrument,
      isHidden: account.isHidden,
      isAutomaticSyncEnabled: false,
      taxOwnerIds: [])

    let updated = draft.applied(to: account)

    #expect(updated.isAutomaticSyncEnabled == false)
  }
}

import SwiftUI

/// "Add Sub-transaction" section in custom-mode editing. The new leg
/// inherits its default account and instrument from the account this
/// editing session is viewing (the currently selected account), falling
/// back to the first sidebar-ordered account so the user always has a
/// sensible starting point to edit from.
struct TransactionDetailAddLegSection: View {
  @Binding var draft: TransactionDraft
  let accounts: Accounts

  var body: some View {
    Section {
      Button("Add Sub-transaction") {
        let defaultAccount =
          draft.viewingAccountId.flatMap { accounts.by(id: $0) }
          ?? accounts.sidebarOrdered().first
        draft.addLeg(
          defaultAccountId: defaultAccount?.id,
          instrument: defaultAccount?.instrument
        )
      }
    }
  }
}

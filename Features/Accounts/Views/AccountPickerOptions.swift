import SwiftUI

/// Picker content for selecting an account. Drop into any `Picker`
/// content closure to render the sidebar's grouping (Current Accounts /
/// Investments) and icon set.
///
/// ```swift
/// Picker("Account", selection: $accountId) {
///   Text("None").tag(UUID?.none)
///   AccountPickerOptions(
///     accounts: accounts,
///     exclude: nil,
///     currentSelection: accountId
///   )
/// }
/// ```
///
/// Sentinel rows like `Text("None").tag(UUID?.none)` stay at the call
/// site so each picker can label its empty state appropriately
/// ("None", "Select…", etc.).
struct AccountPickerOptions: View {
  let accounts: Accounts
  let exclude: UUID?
  let currentSelection: UUID?

  var body: some View {
    let groups = accounts.sidebarGrouped(
      excluding: exclude,
      alwaysInclude: currentSelection
    )
    if !groups.current.isEmpty {
      Section("Current Accounts") {
        ForEach(groups.current) { account in
          Label(account.name, systemImage: account.sidebarIcon)
            .tag(UUID?.some(account.id))
        }
      }
    }
    if !groups.investments.isEmpty {
      Section("Investments") {
        ForEach(groups.investments) { account in
          Label(account.name, systemImage: account.sidebarIcon)
            .tag(UUID?.some(account.id))
        }
      }
    }
  }
}

private func previewAccounts() -> Accounts {
  Accounts(from: [
    Account(
      id: UUID(),
      name: "Chequing",
      type: .bank,
      instrument: .AUD,
      position: 0),
    Account(
      id: UUID(),
      name: "Card",
      type: .creditCard,
      instrument: .AUD,
      position: 1),
    Account(
      id: UUID(),
      name: "Brokerage",
      type: .investment,
      instrument: .AUD,
      position: 0),
  ])
}

private func previewCurrentOnlyAccounts() -> Accounts {
  Accounts(from: [
    Account(
      id: UUID(),
      name: "Chequing",
      type: .bank,
      instrument: .AUD,
      position: 0),
    Account(
      id: UUID(),
      name: "Card",
      type: .creditCard,
      instrument: .AUD,
      position: 1),
  ])
}

#Preview("Account picker — both groups") {
  @Previewable @State var selection: UUID?
  let accounts = previewAccounts()
  return Form {
    Picker("Account", selection: $selection) {
      Text("None").tag(UUID?.none)
      AccountPickerOptions(
        accounts: accounts,
        exclude: nil,
        currentSelection: selection
      )
    }
  }
}

#Preview("Account picker — current accounts only") {
  @Previewable @State var selection: UUID?
  let accounts = previewCurrentOnlyAccounts()
  return Form {
    Picker("Account", selection: $selection) {
      Text("None").tag(UUID?.none)
      AccountPickerOptions(
        accounts: accounts,
        exclude: nil,
        currentSelection: selection
      )
    }
  }
}

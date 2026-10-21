import MoolahMCP
import SwiftUI

struct MCPIntegrationEditorView: View {
  @Environment(MCPServerController.self) private var controller
  @Environment(\.dismiss) private var dismiss
  let profiles: [Profile]
  @State private var draft: MCPIntegrationDraft

  init(profiles: [Profile], grant: MCPGrant? = nil, replacing: Bool = false) {
    self.profiles = profiles
    _draft = State(initialValue: MCPIntegrationDraft(grant: grant, replacing: replacing))
  }

  var body: some View {
    @Bindable var draft = draft
    NavigationStack {
      Form {
        if draft.grant == nil { TextField("Name", text: $draft.label) }
        profilesSection
        permissionsSection
        if draft.grant == nil {
          Toggle("Set an expiry date", isOn: $draft.hasExpiry)
          if draft.hasExpiry { DatePicker("Expires", selection: $draft.expiry) }
        }
        if let message = draft.validationMessage { Text(message).foregroundStyle(.secondary) }
        if let error = controller.errorMessage { Text(error).foregroundStyle(.red) }
      }
      .formStyle(.grouped)
      .navigationTitle(draft.title)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button(draft.actionLabel) {
            draft.submit(to: controller)
          }
          .disabled(draft.validationMessage != nil)
        }
      }
    }
    .frame(minWidth: 500, minHeight: 400)
    .disabled(controller.isBusy)
    .onChange(of: controller.isBusy) { wasBusy, busy in
      if draft.submitted, wasBusy, !busy, controller.errorMessage == nil, draft.grant != nil {
        dismiss()
      }
    }
  }

  private var profilesSection: some View {
    Section("Profiles") {
      ForEach(profiles) { profile in
        Toggle(
          profile.label,
          isOn: membership(
            profile.id,
            in: Binding(
              get: { draft.profileIDs },
              set: { draft.profileIDs = $0 }
            )
          )
        )
      }
      if profiles.isEmpty { Text("Add a profile in Moolah first.") }
    }
  }

  private var permissionsSection: some View {
    Section {
      ForEach(MCPReadScope.allCases, id: \.self) { scope in
        Toggle(
          scope.settingsLabel,
          isOn: membership(
            scope,
            in: Binding(
              get: { draft.scopes },
              set: { draft.scopes = $0 }
            )
          )
        )
      }
    } header: {
      Text("Read permissions")
    } footer: {
      Text(
        "Profile access covers all financial data allowed by the selected permissions, across every account in that profile. Notes need their own permission. An external agent may retain or share data it retrieves; Moolah cannot control that."
      )
    }
  }

  private func membership<Value: Hashable>(_ value: Value, in set: Binding<Set<Value>>) -> Binding<
    Bool
  > {
    Binding(
      get: { set.wrappedValue.contains(value) },
      set: { enabled in
        if enabled { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) }
      }
    )
  }
}

extension MCPReadScope {
  var settingsLabel: String {
    switch self {
    case .profiles: "Profiles and status"
    case .accounts: "Accounts and balances"
    case .transactions: "Transactions"
    case .categories: "Categories"
    case .earmarks: "Earmarks"
    case .summaries: "Financial summaries"
    case .transactionNotes: "Transaction notes (optional)"
    }
  }
}

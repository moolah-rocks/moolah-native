import SwiftUI

struct EditAccountView: View {
  // MARK: - Environment & state

  @Environment(\.dismiss) private var dismiss
  @Environment(ProfileSession.self) private var session
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var name: String
  @State private var type: AccountType
  @State private var currency: Instrument
  @State private var isHidden: Bool
  @State private var isAutomaticSyncEnabled: Bool
  @State private var taxOwnerAssignmentStore: AccountTaxOwnerAssignmentStore
  @State private var isSubmitting = false
  @State private var errorMessage: String?
  /// Write-only replacement for an exchange account's read-only API
  /// token. Empty = keep the stored token (handled by
  /// `EditExchangeTokenLogic.applyTokenChange`).
  @State private var replacementToken = ""
  @FocusState private var focusedField: Field?

  let account: Account
  let accountStore: AccountStore

  private enum Field: Hashable {
    case name
  }

  // MARK: - Init

  init(account: Account, accountStore: AccountStore) {
    self.account = account
    self.accountStore = accountStore
    _name = State(initialValue: account.name)
    _type = State(initialValue: account.type)
    _currency = State(initialValue: account.instrument)
    _isHidden = State(initialValue: account.isHidden)
    _isAutomaticSyncEnabled = State(initialValue: account.isAutomaticSyncEnabled)
    _taxOwnerAssignmentStore = State(
      initialValue: AccountTaxOwnerAssignmentStore(selectedOwnerIds: account.taxOwnerIds))
  }

  private var taxOwnerIdsBinding: Binding<[UUID]> {
    Binding(
      get: { taxOwnerAssignmentStore.selectedOwnerIds },
      set: { taxOwnerAssignmentStore.selectedOwnerIds = $0 }
    )
  }

  // MARK: - Body

  var body: some View {
    NavigationStack {
      form
    }
    #if os(macOS)
      .frame(minWidth: 500, minHeight: 400)
    #endif
  }

  private var form: some View {
    Form {
      detailsSection
        .disabled(isSubmitting)
      automaticSyncSection
        .disabled(isSubmitting)
      exchangeSection
        .disabled(isSubmitting)
      taxOwnerSection
      savingStatusSection
      if let errorMessage {
        Section {
          Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.caption)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Edit Account")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    #if os(macOS)
      .defaultFocus($focusedField, .name)
    #endif
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
          .accessibilityIdentifier(UITestIdentifiers.EditAccount.cancelButton)
          .disabled(isSubmitting)
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") { Task { await save() } }
          .disabled(Self.isSaveDisabled(name: name, isSubmitting: isSubmitting))
          .accessibilityIdentifier(UITestIdentifiers.EditAccount.saveButton)
      }
    }
    .interactiveDismissDisabled(isSubmitting)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: type)
    .task {
      await taxOwnerAssignmentStore.observeOwners(from: session.backend.taxOwners)
    }
    .task {
      await taxOwnerAssignmentStore.observeErrors(from: session.backend.taxOwners)
    }
  }

  @ViewBuilder private var automaticSyncSection: some View {
    if type.isSynced {
      Section {
        Toggle("Automatic Sync", isOn: $isAutomaticSyncEnabled)
          .accessibilityHint(
            "When off, this account only syncs when you choose Sync Now")
      } footer: {
        Text(
          "Turn this off to stop automatic sync. You can still sync the account "
            + "with Sync Now.")
      }
    }
  }

  // MARK: - Sections

  private var detailsSection: some View {
    let canToggleHidden = accountStore.canToggleHidden(account.id)
    return Section {
      TextField("Name", text: $name, prompt: Text("e.g. Savings Account"))
        .focused($focusedField, equals: .name)
        .accessibilityLabel("Account name")
      Picker("Account Type", selection: $type) {
        ForEach(AccountType.allCases, id: \.self) { type in
          Text(type.displayName).tag(type)
        }
      }
      InstrumentPickerField(label: "Currency", kinds: [.fiatCurrency], selection: $currency)
      Toggle("Hidden", isOn: $isHidden)
        .disabled(!canToggleHidden)
        .accessibilityHint(canToggleHidden ? "" : "Account must have zero balance to hide")
    }
  }

  @ViewBuilder private var taxOwnerSection: some View {
    if let taxOwnerErrorMessage = taxOwnerAssignmentStore.errorMessage {
      Section {
        Label(taxOwnerErrorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
      } header: {
        Text("Tax Ownership")
      }
    } else {
      TaxOwnerAssignmentSection(
        title: "Tax Ownership",
        owners: taxOwnerAssignmentStore.owners,
        defaultOwnerId: session.profile.defaultTaxOwnerId,
        footer:
          "Leave no owners selected to use the profile default. Select multiple owners to split tax reporting equally.",
        selectedOwnerIds: taxOwnerIdsBinding
      )
      .disabled(isSubmitting)
    }
  }

  /// Visible only for `.exchange` accounts: a read-only provider label
  /// plus a write-only `SecureField` to replace the stored API token.
  /// The current token is never surfaced (it lives in the keychain, not
  /// the DB). Leaving the field blank keeps the existing token — stated
  /// in the footer because that behaviour is not self-evident.
  @ViewBuilder private var exchangeSection: some View {
    if type == .exchange {
      Section {
        LabeledContent(
          "Exchange",
          value: account.exchangeProvider?.displayName ?? "—")
        SecureField("New token", text: $replacementToken)
          .textContentType(.password)
          .accessibilityLabel("Replace API token")
          .accessibilityHint("Leave blank to keep the existing token")
          .accessibilityIdentifier(
            UITestIdentifiers.EditAccount.exchangeAccessTokenField)
      } footer: {
        // Footer: plain Text, no .foregroundStyle — grouped-Form footers
        // are already secondary.
        Text(
          "Enter a new read-only token to replace the stored one. "
            + "Leave blank to keep the existing token.")
      }
    }
  }

  private func save() async {
    guard !Self.isSaveDisabled(name: name, isSubmitting: isSubmitting) else { return }

    isSubmitting = true
    errorMessage = nil

    let draft = EditAccountDraft(
      name: name,
      type: type,
      instrument: currency,
      isHidden: isHidden,
      isAutomaticSyncEnabled: isAutomaticSyncEnabled,
      taxOwnerIds: taxOwnerAssignmentStore.selectedOwnerIds)
    let updated = Self.updatedAccount(
      from: account, draft: draft, validOwners: taxOwnerAssignmentStore.owners)

    do {
      // Replace the keychain token BEFORE mutating the account row so a
      // token-save failure aborts the whole save (surfaced via
      // `errorMessage`) with no partially-applied edit. No env/session
      // store for this — construct the production token store the same
      // way `CreateAccountView.submitExchange` and `ProfileSession` do
      // (iCloud-synced keychain). A blank field is a no-op.
      try EditExchangeTokenLogic.applyTokenChange(
        token: replacementToken,
        for: account.id,
        using: ExchangeTokenStore(synchronizable: true))
      _ = try await accountStore.update(updated)
      dismiss()
    } catch {
      errorMessage = error.localizedDescription
      isSubmitting = false
    }
  }

}

#Preview("Synced Account — Automatic Sync Off") {
  // In-memory preview sessions cannot fail in practice.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()
  let account = Account(
    name: "Mainnet Wallet",
    type: .crypto,
    instrument: .AUD,
    isAutomaticSyncEnabled: false,
    walletAddress: "0x0000000000000000000000000000000000000000",
    chainId: 1)
  EditAccountView(account: account, accountStore: session.accountStore)
    .previewProfileEnvironment(session: session)
}

extension EditAccountView {
  @ViewBuilder private var savingStatusSection: some View {
    if isSubmitting {
      Section {
        HStack {
          ProgressView()
          Text("Saving account…")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Saving account")
      }
    }
  }

  static func isSaveDisabled(name: String, isSubmitting: Bool) -> Bool {
    name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting
  }
}

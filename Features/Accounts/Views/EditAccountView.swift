import OSLog
import SwiftUI

/// Outcome of the snapshot-presence probe used to decide whether
/// `EditAccountView` offers the Valuation picker. Lifted to module
/// scope (rather than nested inside `EditAccountView`) because tests
/// reference it directly via `@testable import Moolah`. Specific
/// name disambiguates from any future "picker visibility" state in
/// other features. See
/// `plans/2026-05-05-restrict-valuation-picker-design.md` §3.3.
enum ValuationPickerVisibility: Equatable, Sendable {
  case hidden
  case shown
  case shownAfterFailure
}

private let editAccountLogger = Logger(
  subsystem: "com.moolah.app", category: "EditAccountView")

struct EditAccountView: View {
  // MARK: - Environment & state

  @Environment(\.dismiss) private var dismiss
  @Environment(ProfileSession.self) private var session
  @State private var name: String
  @State private var type: AccountType
  @State private var currency: Instrument
  @State private var isHidden: Bool
  @State private var valuationMode: ValuationMode
  @State private var taxOwnerIds: [UUID]
  @State private var taxOwners: [TaxOwner] = []
  @State private var isSubmitting = false
  @State private var errorMessage: String?
  @State private var taxOwnerErrorMessage: String?
  @State private var showValuationPicker: Bool
  @State private var pickerShownDueToProbeFailure = false
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

  // MARK: - Picker visibility

  /// Resolves whether the Valuation picker should be shown for an
  /// investment account currently in `.calculatedFromTrades` mode.
  /// Pure async function over a closure-typed probe so the rule is
  /// directly unit-testable. The `accountId` parameter exists so the
  /// warning log on probe failure can identify which account
  /// triggered it; supply the real account ID for diagnosability.
  /// Re-throws `CancellationError` per the structured-concurrency
  /// contract; converts any other error into `.shownAfterFailure`
  /// (fail-open).
  static func resolvePickerVisibility(
    accountId: UUID,
    snapshotProbe: () async throws -> Bool
  ) async throws -> ValuationPickerVisibility {
    do {
      return try await snapshotProbe() ? .shown : .hidden
    } catch let error as CancellationError {
      throw error
    } catch {
      editAccountLogger.warning(
        "valuation snapshot probe failed for \(accountId, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return .shownAfterFailure
    }
  }

  // MARK: - Init

  init(account: Account, accountStore: AccountStore) {
    self.account = account
    self.accountStore = accountStore
    _name = State(initialValue: account.name)
    _type = State(initialValue: account.type)
    _currency = State(initialValue: account.instrument)
    _isHidden = State(initialValue: account.isHidden)
    _valuationMode = State(initialValue: account.valuationMode)
    _taxOwnerIds = State(initialValue: account.taxOwnerIds)
    // Initial visibility: shown for `.recordedValue` accounts so legacy
    // users see the picker immediately, hidden for `.calculatedFromTrades`
    // accounts pending the snapshot probe in `.task`. See design §3.3.
    _showValuationPicker = State(
      initialValue: account.valuationMode == .recordedValue)
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
      valuationSection
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
    .animation(.easeInOut(duration: 0.2), value: type)
    .task(id: account.id) {
      // Already shown for `.recordedValue` — skip the probe.
      guard !showValuationPicker else { return }
      do {
        let result = try await Self.resolvePickerVisibility(
          accountId: account.id,
          snapshotProbe: {
            try await !session.backend.investments
              .fetchValues(accountId: account.id, page: 0, pageSize: 1)
              .values.isEmpty
          })
        switch result {
        case .hidden:
          showValuationPicker = false
          pickerShownDueToProbeFailure = false
        case .shown:
          showValuationPicker = true
          pickerShownDueToProbeFailure = false
        case .shownAfterFailure:
          showValuationPicker = true
          pickerShownDueToProbeFailure = true
        }
      } catch is CancellationError {
        // View is being dismissed or `account.id` changed; leave state
        // unchanged so SwiftUI's teardown is clean.
      } catch {
        // Unreachable: `resolvePickerVisibility` converts every
        // non-cancellation error into `.shownAfterFailure`. Asserting
        // here turns any future regression into a debug-build crash
        // rather than silently swallowing the error.
        assertionFailure(
          "resolvePickerVisibility threw unexpected error: \(error)")
      }
    }
    .task {
      await observeTaxOwners()
    }
    .task {
      await observeTaxOwnerErrors()
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

  /// Visible only for investment accounts that already have legacy
  /// `InvestmentValue` data (or are currently in `.recordedValue` mode).
  /// New trade-driven accounts never see this section. Footer text
  /// describes the active mode so the user can predict what the
  /// sidebar balance will read; on probe failure, an additional info
  /// note explains that valuation history couldn't be confirmed.
  @ViewBuilder private var valuationSection: some View {
    if type == .investment, showValuationPicker {
      Section {
        Picker("Valuation", selection: $valuationMode) {
          Text("Recorded value").tag(ValuationMode.recordedValue)
          Text("Calculated from trades").tag(ValuationMode.calculatedFromTrades)
        }
        .accessibilityIdentifier(UITestIdentifiers.EditAccount.valuationModePicker)
        .accessibilityHint(valuationMode.dataSourceHint)
      } footer: {
        VStack(alignment: .leading, spacing: 4) {
          Text(valuationMode.dataSourceDescription)
          if pickerShownDueToProbeFailure {
            Label(
              "Couldn't confirm your valuation history. Reopen the dialog to check again.",
              systemImage: "info.circle"
            )
            .foregroundStyle(.secondary)
          }
        }
      }
    }
  }
  @ViewBuilder private var taxOwnerSection: some View {
    if let taxOwnerErrorMessage {
      Section {
        Label(taxOwnerErrorMessage, systemImage: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
      } header: {
        Text("Tax Ownership")
      }
    } else {
      TaxOwnerAssignmentSection(
        title: "Tax Ownership",
        owners: taxOwners,
        defaultOwnerId: session.profile.defaultTaxOwnerId,
        footer:
          "Leave no owners selected to use the profile default. Select multiple owners to split tax reporting equally.",
        selectedOwnerIds: $taxOwnerIds
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
      valuationMode: valuationMode,
      taxOwnerIds: taxOwnerIds)
    let updated = Self.updatedAccount(from: account, draft: draft, validOwners: taxOwners)

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

  private func observeTaxOwners() async {
    for await owners in session.backend.taxOwners.observeAll() {
      guard !Task.isCancelled else { return }
      taxOwners = owners
      taxOwnerIds = TaxOwnerAssignmentState.prunedSelectedOwnerIds(
        taxOwnerIds, validOwners: owners)
      taxOwnerErrorMessage = nil
    }
  }

  private func observeTaxOwnerErrors() async {
    for await _ in session.backend.taxOwners.observeErrors() {
      guard !Task.isCancelled else { return }
      taxOwnerErrorMessage = "Couldn't load tax owners. Reopen the account editor and try again."
    }
  }
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

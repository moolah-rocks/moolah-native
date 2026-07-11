import SwiftUI

@MainActor
private func makePreviewView(account: Account) -> some View {
  let backend = PreviewBackend.create()
  let accountStore = AccountStore(
    repository: backend.accounts,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  // In-memory preview session can't fail in practice: opens an ephemeral
  // GRDB queue with no disk access. A trap here is acceptable in #Preview.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()
  return EditAccountView(account: account, accountStore: accountStore)
    .environment(session)
}

#Preview("Bank account") {
  makePreviewView(
    account: Account(name: "Checking", type: .bank, instrument: .AUD))
}

#Preview("Investment account, recordedValue (picker shown)") {
  makePreviewView(
    account: Account(
      name: "Legacy brokerage",
      type: .investment,
      instrument: .AUD,
      valuationMode: .recordedValue))
}

#Preview("Investment account, calculatedFromTrades (picker hidden)") {
  makePreviewView(
    account: Account(
      name: "New brokerage",
      type: .investment,
      instrument: .AUD,
      valuationMode: .calculatedFromTrades))
}

#Preview("Exchange account (replace-token section)") {
  makePreviewView(
    account: Account(
      name: "My Coinstash",
      type: .exchange,
      instrument: .AUD,
      valuationMode: .calculatedFromTrades,
      exchangeProvider: .coinstash))
}

#Preview("Exchange account (replace-token section, Accessibility3)") {
  makePreviewView(
    account: Account(
      name: "My Coinstash",
      type: .exchange,
      instrument: .AUD,
      valuationMode: .calculatedFromTrades,
      exchangeProvider: .coinstash)
  )
  .dynamicTypeSize(.accessibility3)
}

#Preview("Bank account, tax owner assigned") {
  let partnerOwnerId = failOpenValuationPreviewUUID("22222222-2222-2222-2222-222222222222")
  makePreviewView(
    account: Account(
      name: "Shared spending",
      type: .bank,
      instrument: .AUD,
      taxOwnerIds: [partnerOwnerId]))
}

/// Wrapper that imitates the section structure used by
/// `EditAccountView.valuationSection` so the fail-open footer Label
/// can render in canvas without forcing a preview-only initialiser
/// onto the production view. Adding a debug-flagged init would widen
/// the API surface for a concern the production code never has.
private struct FailOpenValuationPreview: View {
  @State private var mode: ValuationMode = .calculatedFromTrades
  var body: some View {
    Form {
      Section {
        Picker("Valuation", selection: $mode) {
          Text("Recorded value").tag(ValuationMode.recordedValue)
          Text("Calculated from trades").tag(ValuationMode.calculatedFromTrades)
        }
        .accessibilityIdentifier(UITestIdentifiers.EditAccount.valuationModePicker)
        .accessibilityHint(mode.dataSourceHint)
      } footer: {
        VStack(alignment: .leading, spacing: 4) {
          Text(mode.dataSourceDescription)
          Label(
            "Couldn't confirm your valuation history. Reopen the dialog to check again.",
            systemImage: "info.circle"
          )
          .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .frame(minWidth: 500, minHeight: 280)
  }
}

#Preview("Investment account, fail-open footer") {
  FailOpenValuationPreview()
}

#Preview("Investment account, fail-open footer (Accessibility3)") {
  FailOpenValuationPreview()
    .dynamicTypeSize(.accessibility3)
}

private func failOpenValuationPreviewUUID(_ literal: String) -> UUID {
  guard let uuid = UUID(uuidString: literal) else {
    fatalError("Invalid fail-open valuation preview UUID")
  }
  return uuid
}

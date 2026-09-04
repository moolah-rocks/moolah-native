import SwiftUI

/// One-screen Needs Setup form per the design doc. Presented as a sheet from
/// `NeedsSetupAndFailedPanel`. Lets the user pick the target account, review
/// the detected parser / mapping, preview the first five rows, set a
/// filename pattern, and toggle delete-after-import.
struct CSVImportSetupView: View {
  let store: CSVImportSetupStore
  @Environment(AccountStore.self) private var accountStore
  @Environment(\.dismiss) private var dismiss

  @State private var dateFormatChoice: DateFormatChoice = .auto

  enum DateFormatChoice: String, Hashable, CaseIterable, Identifiable {
    case auto
    case ddMMYYYY
    case mmDDYYYY
    case iso

    var id: String { rawValue }
    var label: String {
      switch self {
      case .auto: return "Auto-detect"
      case .ddMMYYYY: return "DD/MM/YYYY"
      case .mmDDYYYY: return "MM/DD/YYYY"
      case .iso: return "YYYY-MM-DD"
      }
    }
  }

  var body: some View {
    NavigationStack {
      form
        .task {
          await store.regeneratePreview()
        }
        .onChange(of: dateFormatChoice) { _, newValue in
          Task { await store.applyDateFormatOverride(newValue.resolved) }
        }
        #if os(macOS)
          .frame(minWidth: 520, minHeight: 480)
        #endif
    }
  }

  private var form: some View {
    Form {
      fileSection
      targetAccountSection
      if store.isGenericParser, let mapping = store.detectedMapping {
        columnMappingSection(mapping: mapping)
      }
      if !store.preview.isEmpty {
        previewSection
      }
      optionsSection
      if let error = store.saveError {
        Label(error, systemImage: "exclamationmark.circle")
          .foregroundStyle(.red)
      }
      // Destructive action lives in the form body, not the toolbar, so
      // it doesn't sit alongside Cancel / Save & Import where users
      // might tap it by accident. See Apple HIG "Destructive actions".
      Section {
        Button("Delete staged file", role: .destructive) {
          Task {
            await store.deletePending()
            dismiss()
          }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Set up CSV import")
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") {
          store.cancel()
          dismiss()
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save & Import") {
          Task {
            _ = await store.saveAndImport()
            if store.saveError == nil {
              dismiss()
            }
          }
        }
        .disabled(store.targetAccountId == nil || store.isSaving)
      }
    }
  }

  private var fileSection: some View {
    Section(header: Text("File")) {
      LabeledContent("Filename", value: store.pending.originalFilename)
      LabeledContent("Rows") {
        Text("\(store.rowCount)").monospacedDigit()
      }
    }
  }

  private var targetAccountSection: some View {
    Section(header: Text("Target account")) {
      Picker(
        "Account",
        selection: Binding(
          get: { store.targetAccountId },
          set: { store.targetAccountId = $0 })
      ) {
        Text("Select…").tag(UUID?.none)
        ForEach(availableAccounts, id: \.id) { account in
          Text(account.name).tag(UUID?.some(account.id))
        }
      }
    }
  }

  private func columnMappingSection(
    mapping: GenericBankCSVParser.ColumnMapping
  ) -> some View {
    Section(header: Text("Column mapping")) {
      columnMappingRows(mapping: mapping)
      Picker("Date format", selection: $dateFormatChoice) {
        ForEach(DateFormatChoice.allCases) { choice in
          Text(choice.label).tag(choice)
        }
      }
      if mapping.dateFormatAmbiguous {
        Label(
          "Dates are ambiguous — pick the format to match your file.",
          systemImage: "exclamationmark.triangle"
        )
        .foregroundStyle(.orange)
        .font(.caption)
      }
    }
  }

  private var previewSection: some View {
    Section(header: Text("Preview (first 5 rows)")) {
      ForEach(Array(store.preview.enumerated()), id: \.offset) { _, transaction in
        PreviewRow(transaction: transaction)
      }
    }
  }

  private var optionsSection: some View {
    Section(header: Text("Options")) {
      TextField(
        "Filename pattern",
        text: Binding(
          get: { store.filenamePattern },
          set: { store.filenamePattern = $0 })
      )
      Toggle(
        "Delete CSV after import",
        isOn: Binding(
          get: { store.deleteAfterImport },
          set: { store.deleteAfterImport = $0 }))
    }
  }

  private var availableAccounts: [Account] {
    accountStore.accounts.ordered.filter { !$0.isHidden }
  }

  @ViewBuilder
  private func columnMappingRows(
    mapping: GenericBankCSVParser.ColumnMapping
  ) -> some View {
    // Editable: one row per CSV column, dropdown picks the role. Default
    // reflects the detector's mapping; user overrides flow through
    // `store.applyColumnRole(_:forColumn:)` which regenerates the preview.
    ForEach(Array(store.detectedHeaders.enumerated()), id: \.offset) { index, header in
      HStack {
        Text(header).lineLimit(1)
        Spacer()
        Picker(
          "Role",
          selection: Binding(
            get: { roleForColumn(index: index, mapping: mapping) },
            set: { newRole in
              let effectiveRole: CSVImportSetupStore.ColumnRole? =
                (newRole == .ignore) ? nil : newRole
              Task { await store.applyColumnRole(effectiveRole, forColumn: index) }
            })
        ) {
          ForEach(CSVImportSetupStore.ColumnRole.allCases) { role in
            Text(role.label).tag(role)
          }
        }
        .labelsHidden()
      }
    }
  }

  /// Returns the user's chosen role for this column index if set; otherwise
  /// derives the role from the detected mapping. `.ignore` is the displayed
  /// role for any column whose index isn't used by the mapping.
  private func roleForColumn(
    index: Int, mapping: GenericBankCSVParser.ColumnMapping
  ) -> CSVImportSetupStore.ColumnRole {
    if index < store.columnRoles.count, let override = store.columnRoles[index] {
      return override
    }
    if mapping.date == index { return .date }
    if mapping.description == index { return .description }
    if mapping.amount == index { return .amount }
    if mapping.debit == index { return .debit }
    if mapping.credit == index { return .credit }
    if mapping.balance == index { return .balance }
    if mapping.reference == index { return .reference }
    return .ignore
  }
}

extension CSVImportSetupView.DateFormatChoice {
  /// Resolve to a concrete `GenericBankCSVParser.DateFormat` when the user
  /// overrides detection. `nil` means "use the detector's pick".
  var resolved: GenericBankCSVParser.DateFormat? {
    switch self {
    case .auto: return nil
    case .ddMMYYYY: return .ddMMyyyy(separator: "/")
    case .mmDDYYYY: return .mmDDyyyy(separator: "/")
    case .iso: return .iso
    }
  }
}

/// Renders one preview row using the parsed payee/amount/date — the rules
/// engine hasn't run yet so the payee is the raw description.
private struct PreviewRow: View {
  let transaction: ParsedTransaction
  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(transaction.rawDescription).lineLimit(1)
        Text(transaction.date, format: .dateTime.day().month().year())
          .font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
      Spacer()
      Text(transaction.rawAmount, format: .number.precision(.fractionLength(2)))
        .monospacedDigit()
    }
  }
}

import SwiftUI

/// Sheet for creating a new profile.
struct ProfileFormView: View {
  @Environment(ProfileStore.self) private var profileStore
  @Environment(\.dismiss) private var dismiss

  #if os(macOS)
    @Environment(\.openWindow) private var openWindow
  #endif

  @State private var name = ""
  @State private var currency = Instrument.fiat(
    code: Locale.current.currency?.identifier ?? "AUD")
  @State private var financialYearStartMonth = 7

  private static let monthNames: [String] = {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    return formatter.monthSymbols ?? []
  }()

  var body: some View {
    NavigationStack {
      form
    }
  }

  private var form: some View {
    Form {
      profileSection
      if let error = profileStore.validationError {
        Section {
          Label(error, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .accessibilityLabel("Error: \(error)")
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle("Add Profile")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") {
          profileStore.clearValidationError()
          dismiss()
        }
      }
      ToolbarItem(placement: .confirmationAction) {
        if profileStore.isValidating {
          ProgressView().controlSize(.small)
        } else {
          Button("Add") { Task { await save() } }
            .disabled(!canAdd)
        }
      }
    }
  }

  private var profileSection: some View {
    Section("Profile") {
      TextField("Name", text: $name)
      InstrumentPickerField(label: "Currency", kinds: [.fiatCurrency], selection: $currency)
      Picker("Financial Year Starts", selection: $financialYearStartMonth) {
        ForEach(1...12, id: \.self) { month in
          if month <= Self.monthNames.count {
            Text(Self.monthNames[month - 1]).tag(month)
          }
        }
      }
    }
  }

  private var canAdd: Bool {
    !name.trimmingCharacters(in: .whitespaces).isEmpty
  }

  private func save() async {
    let trimmedName = name.trimmingCharacters(in: .whitespaces)
    guard !trimmedName.isEmpty else { return }
    let profile = Profile(
      label: trimmedName,
      currencyCode: currency.id,
      financialYearStartMonth: financialYearStartMonth
    )

    if await profileStore.validateAndAddProfile(profile) {
      #if os(macOS)
        ProfileWindowLocator.openOrActivate(profile.id, openWindow: openWindow)
      #else
        profileStore.setActiveProfile(profile.id)
      #endif
      dismiss()
    }
  }

}

import SwiftUI

// Profile detail views. `SettingsView.profileDetailView(for:)` routes
// here; each view maintains its own form state and persists changes back
// through `ProfileStore`.

/// Settings detail for an iCloud profile. Shows profile metadata and tax-owner controls.
struct CloudKitProfileDetailView: View {
  let profile: Profile

  @State private var label: String
  @State private var currency: Instrument
  @State private var financialYearStartMonth: Int
  @State private var taxOwnerStore: TaxOwnerStore?
  @State private var metadataSaveStore: CloudKitProfileMetadataSaveStore
  private static let monthNames: [String] = {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    return formatter.monthSymbols ?? []
  }()

  init(
    profile: Profile,
    taxOwnerRepository: (any TaxOwnerRepository)? = nil,
    updateProfile: @escaping @MainActor ((inout Profile) -> Void) async throws -> Profile? = { _ in
      nil
    }
  ) {
    self.profile = profile
    _label = State(initialValue: profile.label)
    _currency = State(initialValue: Instrument.fiat(code: profile.currencyCode))
    _financialYearStartMonth = State(initialValue: profile.financialYearStartMonth)

    let createdTaxOwnerStore: TaxOwnerStore?
    if let taxOwnerRepository {
      createdTaxOwnerStore = TaxOwnerStore(
        profile: profile,
        repository: taxOwnerRepository
      ) { updated in
        _ = try await updateProfile { profile in
          profile.defaultTaxOwnerId = updated.defaultTaxOwnerId
        }
      }
    } else {
      createdTaxOwnerStore = nil
    }
    _taxOwnerStore = State(initialValue: createdTaxOwnerStore)
    _metadataSaveStore = State(
      initialValue: CloudKitProfileMetadataSaveStore(updateProfile: updateProfile) { error in
        createdTaxOwnerStore?.present(error)
      })
  }

  var body: some View {
    Form {
      profileSection
      settingsSection
      taxOwnersSection
    }
    .formStyle(.grouped)
    .accessibilityIdentifier(UITestIdentifiers.TaxOwnerSettings.container)
  }

  private var profileSection: some View {
    Section("Profile") {
      TextField("Name", text: $label)
        .onChange(of: label) { _, _ in saveChanges() }

      HStack {
        Text("Storage")
        Spacer()
        Label("iCloud", systemImage: "icloud")
          .foregroundStyle(.secondary)
      }
    }
  }

  private var settingsSection: some View {
    Section("Settings") {
      InstrumentPickerField(label: "Currency", kinds: [.fiatCurrency], selection: $currency)
        .onChange(of: currency) { _, _ in saveChanges() }

      Picker("Financial Year Starts", selection: $financialYearStartMonth) {
        ForEach(1...12, id: \.self) { month in
          if month <= Self.monthNames.count {
            Text(Self.monthNames[month - 1])
              .tag(month)
          }
        }
      }
      .onChange(of: financialYearStartMonth) { _, _ in saveChanges() }
    }
  }

  private var taxOwnersSection: some View {
    Group {
      if let taxOwnerStore {
        TaxOwnerManagementSection(store: taxOwnerStore)
      } else {
        Section("Tax Owners") {
          ContentUnavailableView(
            "Open Profile Required",
            systemImage: "person.crop.circle",
            description: Text("Open this profile before managing tax owners.")
          )
        }
      }
    }
  }

  private func saveChanges() {
    let trimmedLabel = label.trimmingCharacters(in: .whitespaces)
    guard !trimmedLabel.isEmpty else { return }

    let updatedCurrencyCode = currency.id
    let updatedFinancialYearStartMonth = financialYearStartMonth

    metadataSaveStore.scheduleSave(
      label: trimmedLabel,
      currencyCode: updatedCurrencyCode,
      financialYearStartMonth: updatedFinancialYearStartMonth)
  }
}

#Preview("CloudKit profile — tax owners") {
  let defaultOwnerId = cloudKitProfileDetailPreviewUUID("11111111-1111-1111-1111-111111111111")
  let trustOwnerId = cloudKitProfileDetailPreviewUUID("22222222-2222-2222-2222-222222222222")
  CloudKitProfileDetailView(
    profile: Profile(label: "Family", defaultTaxOwnerId: defaultOwnerId),
    taxOwnerRepository: PreviewTaxOwnerRepository(owners: [
      TaxOwner(id: defaultOwnerId, name: "Alex", kind: .individual),
      TaxOwner(id: trustOwnerId, name: "Family Trust", kind: .trust),
    ])
  ) { _ in
    nil
  }
}

private func cloudKitProfileDetailPreviewUUID(_ literal: String) -> UUID {
  guard let uuid = UUID(uuidString: literal) else {
    fatalError("Invalid CloudKit profile detail preview UUID")
  }
  return uuid
}

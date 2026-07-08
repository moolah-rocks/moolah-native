import SwiftUI

struct TaxOwnerAssignmentState: Equatable, Sendable {
  let owners: [TaxOwner]
  let defaultOwnerId: UUID
  let selectedOwnerIds: [UUID]
  let emptySelectionDescription: String
  let emptySelectionSummary: String?

  init(
    owners: [TaxOwner],
    defaultOwnerId: UUID,
    selectedOwnerIds: [UUID],
    emptySelectionDescription: String = "Profile default",
    emptySelectionSummary: String? = nil
  ) {
    self.owners = owners
    self.defaultOwnerId = defaultOwnerId
    self.selectedOwnerIds = selectedOwnerIds
    self.emptySelectionDescription = emptySelectionDescription
    self.emptySelectionSummary = emptySelectionSummary
  }

  var showsControls: Bool {
    owners.count > 1
  }

  var summary: String {
    let names = selectedOwnerNames
    guard !names.isEmpty else {
      return emptySelectionSummary ?? "\(emptySelectionDescription): \(defaultOwnerName)"
    }
    return names.joined(separator: ", ")
  }

  func isSelected(_ ownerId: UUID) -> Bool {
    selectedOwnerIds.contains(ownerId)
  }

  func selection(setting ownerId: UUID, isSelected: Bool) -> [UUID] {
    var selected = Set(selectedOwnerIds)
    if isSelected {
      selected.insert(ownerId)
    } else {
      selected.remove(ownerId)
    }
    return owners.map(\.id).filter { selected.contains($0) }
  }

  static func prunedSelectedOwnerIds(_ ids: [UUID], validOwners owners: [TaxOwner]) -> [UUID] {
    guard !owners.isEmpty else { return ids }
    let validIds = Set(owners.map(\.id))
    return ids.filter { validIds.contains($0) }
  }

  private var defaultOwnerName: String {
    owners.first { $0.id == defaultOwnerId }?.name ?? "profile default"
  }

  private var selectedOwnerNames: [String] {
    let selected = Set(selectedOwnerIds)
    return owners.compactMap { owner in
      selected.contains(owner.id) ? owner.name : nil
    }
  }
}

struct TaxOwnerAssignmentSection: View {
  let title: String
  let owners: [TaxOwner]
  let defaultOwnerId: UUID
  let footer: String
  let summaryLabel: String
  let emptySelectionDescription: String
  let emptySelectionSummary: String?
  let clearSelectionLabel: String
  @Binding var selectedOwnerIds: [UUID]

  init(
    title: String,
    owners: [TaxOwner],
    defaultOwnerId: UUID,
    footer: String,
    summaryLabel: String = "Tax owners",
    emptySelectionDescription: String = "Profile default",
    emptySelectionSummary: String? = nil,
    clearSelectionLabel: String = "Use profile default",
    selectedOwnerIds: Binding<[UUID]>
  ) {
    self.title = title
    self.owners = owners
    self.defaultOwnerId = defaultOwnerId
    self.footer = footer
    self.summaryLabel = summaryLabel
    self.emptySelectionDescription = emptySelectionDescription
    self.emptySelectionSummary = emptySelectionSummary
    self.clearSelectionLabel = clearSelectionLabel
    _selectedOwnerIds = selectedOwnerIds
  }

  private var state: TaxOwnerAssignmentState {
    TaxOwnerAssignmentState(
      owners: owners,
      defaultOwnerId: defaultOwnerId,
      selectedOwnerIds: selectedOwnerIds,
      emptySelectionDescription: emptySelectionDescription,
      emptySelectionSummary: emptySelectionSummary)
  }

  var body: some View {
    if state.showsControls {
      Section {
        LabeledContent(summaryLabel, value: state.summary)
        Button(clearSelectionLabel) {
          selectedOwnerIds = []
        }
        .disabled(selectedOwnerIds.isEmpty)
        .accessibilityHint("Clears the explicit tax-owner assignment and uses the default.")

        ForEach(owners) { owner in
          Toggle(
            owner.name,
            isOn: Binding(
              get: { state.isSelected(owner.id) },
              set: { isSelected in
                selectedOwnerIds = state.selection(
                  setting: owner.id,
                  isSelected: isSelected)
              })
          )
          .accessibilityLabel("Tax owner, \(owner.name)")
          .accessibilityHint(
            "Includes \(owner.name) in tax reporting. Multiple selected owners split reporting equally."
          )
        }
      } header: {
        Text(title)
      } footer: {
        Text(footer)
      }
    }
  }
}

import Foundation

struct TaxReportOwnerSelection {
  struct Choice: Identifiable, Hashable {
    let id: UUID?
    let label: String
  }

  let choices: [Choice]
  let selectedOwnerId: UUID?
  let isPickerVisible: Bool

  static func options(
    for ownerNames: [UUID: String],
    selectedOwnerId: UUID? = nil
  ) -> TaxReportOwnerSelection {
    let owners = ownerNames.sorted { lhs, rhs in
      if lhs.value != rhs.value {
        return lhs.value.localizedStandardCompare(rhs.value) == .orderedAscending
      }
      return lhs.key.uuidString < rhs.key.uuidString
    }
    let isPickerVisible = owners.count > 1
    let choices =
      if isPickerVisible {
        [Choice(id: nil, label: "All owners")] + owners.map { Choice(id: $0.key, label: $0.value) }
      } else {
        [Choice(id: nil, label: "All owners")]
      }
    let selectedOwnerId = selectedOwnerId.flatMap { id in
      ownerNames.keys.contains(id) ? id : nil
    }
    return TaxReportOwnerSelection(
      choices: choices,
      selectedOwnerId: selectedOwnerId,
      isPickerVisible: isPickerVisible)
  }
}

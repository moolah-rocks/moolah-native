import Foundation

struct CategoryTaxOwnerOverridePresentation: Equatable, Sendable {
  static let footer =
    "Leave no owners selected to use the transaction account's tax ownership, falling back to the profile default when the account has no owners."
  static let emptySelectionDescription = "Account/profile default"
  static let emptySelectionSummary = "Uses transaction account tax ownership"
  static let clearSelectionLabel = "Use account/profile default"

  let isTaxReportable: Bool
  let ownerCount: Int
  let errorMessage: String?

  var showsControls: Bool {
    isTaxReportable && errorMessage == nil && ownerCount > 1
  }

  var showsUnavailableMessage: Bool {
    isTaxReportable && errorMessage != nil
  }

  var isVisible: Bool {
    showsControls || showsUnavailableMessage
  }
}

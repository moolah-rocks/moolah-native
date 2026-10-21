import Foundation
import MoolahMCP
import Observation

@MainActor
@Observable
final class MCPIntegrationDraft {
  let grant: MCPGrant?
  let isReplacement: Bool
  let now: @Sendable () -> Date
  var label: String
  var profileIDs: Set<UUID>
  var scopes: Set<MCPReadScope>
  var hasExpiry = false
  var expiry: Date
  var submitted = false

  init(
    grant: MCPGrant? = nil,
    replacing: Bool = false,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.grant = replacing ? nil : grant
    isReplacement = replacing
    self.now = now
    label = grant?.label ?? ""
    profileIDs = grant?.profileIDs ?? []
    scopes = grant?.scopes ?? MCPReadScope.standard
    hasExpiry = replacing && grant?.expiresAt != nil
    let duration = grant.flatMap { value in
      value.expiresAt.map { $0.timeIntervalSince(value.createdAt) }
    }
    expiry = now().addingTimeInterval(duration ?? 30 * 86400)
  }

  var title: String {
    if isReplacement { return "Create replacement" }
    return grant == nil ? "Create integration" : "Edit integration access"
  }

  var actionLabel: String {
    if isReplacement { return "Create Replacement Credential" }
    return grant == nil ? "Create Credential" : "Save Access"
  }

  var validationMessage: String? {
    if grant == nil {
      if label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "Enter an integration name."
      }
      if label.trimmingCharacters(in: .whitespacesAndNewlines).utf8.count > 120 {
        return "Use a shorter integration name."
      }
      if hasExpiry, expiry <= now() { return "Choose an expiry date in the future." }
    }
    if profileIDs.isEmpty { return "Select at least one profile." }
    if scopes.isEmpty { return "Select at least one read permission." }
    return nil
  }

  func submit(to controller: MCPServerController) {
    guard validationMessage == nil else { return }
    submitted = true
    if let grant {
      controller.editIntegration(id: grant.id, profileIDs: profileIDs, scopes: scopes)
    } else {
      controller.createIntegration(
        label: label,
        profileIDs: profileIDs,
        scopes: scopes,
        expiresAt: hasExpiry ? expiry : nil
      )
    }
  }
}

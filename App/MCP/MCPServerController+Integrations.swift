import Foundation
import MoolahMCP

extension MCPServerController {
  func createIntegration(
    label: String,
    profileIDs: Set<UUID>,
    scopes: Set<MCPReadScope>,
    expiresAt: Date?
  ) {
    perform { controller in
      let store = try await controller.openGrantStore()
      controller.createdCredential = try await store.create(
        label: label,
        profileIDs: profileIDs,
        scopes: scopes,
        expiresAt: expiresAt
      )
      try await controller.refreshMetadata()
      if controller.isEnabled { await controller.reconcileLeases() }
    }
  }

  func editIntegration(id: UUID, profileIDs: Set<UUID>, scopes: Set<MCPReadScope>) {
    perform { controller in
      let store = try await controller.openGrantStore()
      try await store.updatePermissions(id: id, profileIDs: profileIDs, scopes: scopes)
      try await controller.refreshMetadata()
      if controller.isEnabled { await controller.reconcileLeases() }
    }
  }

  func revokeIntegration(_ id: UUID) {
    perform { controller in
      let store = try await controller.openGrantStore()
      try await store.revoke(id: id)
      try await controller.refreshMetadata()
      if controller.isEnabled { await controller.reconcileLeases() }
    }
  }

  func removeRevokedIntegration(_ id: UUID) {
    perform { controller in
      let store = try await controller.openGrantStore()
      try await store.removeRevoked(id: id)
      try await controller.refreshMetadata()
    }
  }
}

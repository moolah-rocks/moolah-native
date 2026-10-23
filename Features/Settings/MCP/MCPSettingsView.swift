import MoolahMCP
import SwiftUI

struct MCPSettingsView: View {
  @Environment(MCPServerController.self) private var controller
  @Environment(ProfileStore.self) private var profileStore
  @State private var port = ""
  @State private var sheet: MCPSettingsSheet?
  @State private var removingGrant: MCPGrant?
  @State private var showClearHistory = false
  @State private var revokingGrant: MCPGrant?

  var body: some View {
    Form {
      serverSection
      integrationsSection
      readinessSection
      historySection
    }
    .formStyle(.grouped)
    .disabled(controller.isBusy)
    .onAppear {
      port = String(controller.port)
      controller.loadSettings()
    }
    .onDisappear { controller.dismissCredential() }
    .sheet(item: $sheet) { selection in
      if let credential = controller.createdCredential {
        MCPCredentialView(credential: credential)
      } else {
        switch selection {
        case .create, .credential:
          MCPIntegrationEditorView(profiles: profileStore.profiles)
        case .edit(let grant):
          MCPIntegrationEditorView(profiles: profileStore.profiles, grant: grant)
        case .replace(let grant):
          MCPIntegrationEditorView(profiles: profileStore.profiles, grant: grant, replacing: true)
        }
      }
    }
    .onChange(of: controller.createdCredential?.grant.id) { _, id in
      if id != nil { sheet = .credential }
    }
    .confirmationDialog(
      "Revoke integration?",
      isPresented: Binding(
        get: { revokingGrant != nil },
        set: { if !$0 { revokingGrant = nil } }
      ),
      titleVisibility: .visible
    ) {
      if let grant = revokingGrant {
        Button("Revoke \(grant.label)", role: .destructive) {
          controller.revokeIntegration(grant.id)
          revokingGrant = nil
        }
      }
    } message: {
      Text(
        "This credential will stop working immediately. Queries already running will be cancelled."
      )
    }
  }

  private var serverSection: some View {
    Section {
      Toggle(
        "Enable read-only MCP access",
        isOn: Binding(
          get: { controller.isEnabled },
          set: { controller.configure(enabled: $0, port: controller.port) }
        )
      )
      LabeledContent("Status", value: controller.statusText)
      LabeledContent("Endpoint") {
        Text(controller.endpoint).textSelection(.enabled)
      }
      HStack {
        TextField("Port", text: $port)
          .frame(maxWidth: 180)
        Button("Apply Port") {
          controller.applyPort(port)
        }
        .disabled(MCPServerPreferences.portValidationMessage(port) != nil)
      }
      if let validation = MCPServerPreferences.portValidationMessage(port) {
        Text(validation).foregroundStyle(.secondary)
      }
      if let message = controller.errorMessage {
        Text(message).foregroundStyle(.red)
      }
    } header: {
      Text("MCP")
    } footer: {
      Text(
        "The MCP listener is available only on this Mac. MCP is off until you enable it. If you leave it enabled, it starts whenever you open Moolah."
      )
    }
  }

  private var integrationsSection: some View {
    Section {
      if controller.grants.isEmpty {
        Text("Create an integration to choose its profiles and permissions.")
          .foregroundStyle(.secondary)
      }
      ForEach(controller.grants) { grant in integrationRow(grant) }
      Button("Create Integration") { sheet = .create }
    } header: {
      Text("Integrations")
    } footer: {
      Text(
        "A replacement creates a new credential. Revoke the old integration after updating your client."
      )
    }
    .confirmationDialog(
      "Remove revoked integration?",
      isPresented: Binding(
        get: { removingGrant != nil },
        set: { if !$0 { removingGrant = nil } }
      ),
      titleVisibility: .visible
    ) {
      if let grant = removingGrant {
        Button("Remove integration", role: .destructive) {
          controller.removeRevokedIntegration(grant.id)
          removingGrant = nil
        }
      }
      Button("Cancel", role: .cancel) { removingGrant = nil }
    } message: {
      Text(
        "This removes the revoked integration from Moolah. Its activity history remains for up to seven days."
      )
    }

  }

  private func integrationRow(_ grant: MCPGrant) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(grant.label).font(.headline)
        if grant.revokedAt != nil {
          Text("Revoked").foregroundStyle(.secondary)
        } else if controller.isExpired(grant) {
          Text("Expired").foregroundStyle(.secondary)
        }
      }
      LabeledContent("Credential ID", value: grant.id.uuidString).font(.caption).textSelection(
        .enabled
      )
      LabeledContent("Last used") { timestamp(grant.lastUsedAt, fallback: "Never") }
      LabeledContent("Expires") { timestamp(grant.expiresAt, fallback: "No expiry") }
      HStack {
        if grant.revokedAt != nil {
          Button("Remove Integration…", role: .destructive) { removingGrant = grant }
        } else {
          Button("Edit Access") { sheet = .edit(grant) }
          Button("Create Replacement") { sheet = .replace(grant) }
          Button("Revoke Integration…", role: .destructive) { revokingGrant = grant }
        }
      }
    }
    .padding(.vertical, 4)
  }

  @ViewBuilder
  private func timestamp(_ date: Date?, fallback: String) -> some View {
    if let date {
      Text(date, format: .dateTime.year().month().day().hour().minute().second()).monospacedDigit()
    } else {
      Text(fallback)
    }
  }

  private var readinessSection: some View {
    Section("Profile readiness") {
      if controller.readiness.isEmpty {
        Text(
          controller.readinessEmptyMessage
        ).foregroundStyle(.secondary)
      }
      ForEach(controller.readinessIDs, id: \.self) { id in
        VStack(alignment: .leading) {
          LabeledContent(
            profileStore.profiles.first(where: { $0.id == id })?.label ?? "Unavailable profile",
            value: controller.readinessText(profileID: id)
          )
          Text(id.uuidString).font(.caption).textSelection(.enabled)
        }
      }
      Button("Refresh Status") { controller.refresh() }
      Text(
        "Sync status reflects iCloud activity on this Mac. Local results may not include recent changes from your other devices."
      )
      .foregroundStyle(.secondary)
    }
  }

  private var historySection: some View {
    let recentAudit = Array(controller.auditEntries.suffix(20).reversed())
    return Section("Local activity") {
      Text(
        "Keeps up to 1,000 calls for seven days on this Mac: time, credential ID, tool, profile ID, duration and outcome. Query contents and credential tokens are never recorded."
      )
      .foregroundStyle(.secondary)
      if controller.auditEntries.isEmpty {
        Text("No activity yet. Calls from your integrations appear here.").foregroundStyle(
          .secondary
        )
      }
      ForEach(recentAudit.indices, id: \.self) { index in
        let entry = recentAudit[index]
        VStack(alignment: .leading) {
          HStack {
            Text(entry.timestamp, format: .dateTime.year().month().day().hour().minute().second())
              .monospacedDigit()
            Text(entry.tool)
            Spacer()
            Text(entry.outcome)
          }
          Text(entry.credentialID.uuidString).font(.caption).foregroundStyle(.secondary)
        }
      }
      Button("Clear Activity History…", role: .destructive) { showClearHistory = true }
    }
    .confirmationDialog(
      "Clear activity history?",
      isPresented: $showClearHistory,
      titleVisibility: .visible
    ) {
      Button("Clear history", role: .destructive) { controller.clearHistory() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This permanently deletes all local MCP activity records on this Mac.")
    }

  }
}

private enum MCPSettingsSheet: Identifiable {
  case create
  case edit(MCPGrant)
  case replace(MCPGrant)
  case credential

  var id: String { "mcp-settings-sheet" }
}

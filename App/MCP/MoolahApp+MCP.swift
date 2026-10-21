import Foundation
import MoolahMCP

extension MoolahApp {
  static func makeMCPController(
    sessions: SessionManager,
    isolated: Bool
  ) -> MCPServerController {
    let preferences: MCPServerPreferences
    if isolated {
      // Test-host launches must not read real enablement or start a listener.
      let suite = "rocks.moolah.mcp-tests.\(UUID().uuidString)"
      guard let defaults = UserDefaults(suiteName: suite) else {
        preconditionFailure("Unable to create isolated MCP defaults")
      }
      defaults.removePersistentDomain(forName: suite)
      preferences = MCPServerPreferences(defaults: defaults)
    } else {
      preferences = MCPServerPreferences()
    }
    let directory =
      isolated
      ? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      : URL.applicationSupportDirectory.appending(path: "moolah/MCP", directoryHint: .isDirectory)
    let controller = MCPServerController(
      sessions: sessions,
      preferences: preferences,
      persistence: isolated
        ? MCPTransientSecrets()
        : MCPKeychainPersistence(service: "rocks.moolah.app.mcp.grants"),
      history: MCPAuditHistory(url: directory.appendingPathComponent("audit.json")),
      makeTools: { grants in
        try MCPToolRegistry(service: MoolahReadQueryService(sessions: sessions), grants: grants)
          .tools
      }
    )
    controller.startIfEnabled()
    return controller
  }
}

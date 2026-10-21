import Foundation
import MCP
import MoolahMCP
import Synchronization

/// Isolated real-server fixture. Its generated credential travels only over a dedicated pipe.
/// The in-memory verifier store never opens the app, Keychain, or financial profiles.
@main
enum MCPTransportSpike {
  static func main() async throws {
    guard CommandLine.arguments.count == 3,
      let port = Int(CommandLine.arguments[1]),
      let descriptor = Int32(CommandLine.arguments[2]), descriptor >= 3
    else { throw MCPConfigurationError.invalidEndpoint }
    let policy = try MCPRequestPolicy(port: port)
    let grants = try await MCPGrantStore.open(persistence: FixtureSecrets())
    let credential = try await grants.create(
      label: "Transport fixture",
      profileIDs: [UUID()],
      scopes: [.profiles]
    )
    let pipe = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    try pipe.write(contentsOf: Data((credential.token + "\n").utf8))
    try pipe.close()
    let endpoint = try MCPAuthenticatedEndpoint(
      policy: policy,
      grants: grants,
      tools: [
        MCPAuthorizedTool(schema: tool, scope: .profiles, requiresProfile: false) { invocation in
          guard invocation.arguments.isEmpty else { throw MCPAccessFailure.invalidFilter }
          return .init(
            content: [.text(text: "Transport probe succeeded", annotations: nil, _meta: nil)],
            structuredContent: .object(["ready": .bool(true)])
          )
        }
      ]
    )
    try await endpoint.run {
      FileHandle.standardOutput.write(Data("READY http://127.0.0.1:\(port)/mcp\n".utf8))
    }
  }

  private static let tool = Tool(
    name: "moolah_transport_probe",
    description: "Synthetic transport fixture. No financial data is available.",
    inputSchema: .object([
      "type": .string("object"), "properties": .object([:]),
      "additionalProperties": .bool(false),
    ]),
    outputSchema: .object([
      "type": .string("object"),
      "properties": .object(["ready": .object(["type": .string("boolean")])]),
      "required": .array([.string("ready")]),
    ])
  )
}

private final class FixtureSecrets: MCPSecretPersisting {
  let data = Mutex<Data?>(nil)

  func readData() throws -> Data? { data.withLock { $0 } }
  func writeData(_ value: Data) throws { data.withLock { $0 = value } }
}

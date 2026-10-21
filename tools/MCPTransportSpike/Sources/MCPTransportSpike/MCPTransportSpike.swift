import CryptoKit
import Foundation
import MCP
import MoolahMCP

/// Isolated handshake fixture. Reads an ephemeral bearer token from stdin; never opens Moolah data.
@main
enum MCPTransportSpike {
  static func main() async throws {
    guard let token = readLine(), token.utf8.count >= 32 else {
      throw MCPConfigurationError.invalidEndpoint
    }
    let expected = Array(SHA256.hash(data: Data(token.utf8)))
    let port: Int
    if CommandLine.arguments.count == 1 {
      port = 49_137
    } else if CommandLine.arguments.count == 2, let value = Int(CommandLine.arguments[1]) {
      port = value
    } else {
      throw MCPConfigurationError.invalidEndpoint
    }
    let policy = try MCPRequestPolicy(port: port)
    let host = MCPLoopbackHost(policy: policy)
    try await host.run { request in
      guard let authorization = request.header("Authorization"),
        authorization.hasPrefix("Bearer ")
      else { return false }
      let candidate = Array(SHA256.hash(data: Data(authorization.dropFirst(7).utf8)))
      return zip(expected, candidate).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    } respond: { request in
      try await MCPProtocolAdapter.respond(to: request, tools: [tool]) { params in
        guard params.name == "moolah_transport_probe", params.arguments?.isEmpty != false else {
          throw MCPError.invalidParams("Unknown tool or arguments")
        }
        return .init(
          content: [.text(text: "Transport probe succeeded", annotations: nil, _meta: nil)],
          structuredContent: .object(["ready": .bool(true)]))
      }
    } onRunning: {
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
    annotations: .init(
      readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false),
    outputSchema: .object([
      "type": .string("object"),
      "properties": .object(["ready": .object(["type": .string("boolean")])]),
      "required": .array([.string("ready")]),
    ]))
}

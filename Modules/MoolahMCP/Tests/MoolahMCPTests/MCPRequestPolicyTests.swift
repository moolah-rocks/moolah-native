import Foundation
import MCP
import Testing

@testable import MoolahMCP

struct MCPRequestPolicyTests {
  @Test
  func rejectsUnsafePorts() {
    #expect(throws: MCPConfigurationError.self) { try MCPRequestPolicy(port: 80) }
    #expect(throws: MCPConfigurationError.self) { try MCPRequestPolicy(port: 65_536) }
  }

  @Test
  func validatesExactAuthorityAndOrigin() throws {
    let policy = try MCPRequestPolicy(port: 49_137)
    #expect(policy.rejection(for: request(host: "127.0.0.1:49137")) == nil)
    #expect(policy.rejection(for: request(host: "evil.test:49137"))?.statusCode == 403)
    #expect(policy.rejection(for: request(host: "127.0.0.1:49137.evil.test")) != nil)
    #expect(policy.rejection(for: request(host: "127.0.0.1:49137", origin: "null")) != nil)
    #expect(
      policy.rejection(for: request(host: "127.0.0.1:49137", origin: "https://evil.test")) != nil)
  }

  @Test
  func allowsOnlyConfiguredOrigins() throws {
    let policy = try MCPRequestPolicy(
      port: 49_137, allowedOrigins: ["http://127.0.0.1:49137"])
    #expect(
      policy.rejection(
        for: request(
          host: "127.0.0.1:49137", origin: "http://127.0.0.1:49137")) == nil)
    #expect(throws: MCPConfigurationError.self) {
      try MCPRequestPolicy(port: 49_137, allowedOrigins: ["*"])
    }
  }

  private func request(host: String, origin: String? = nil) -> HTTPRequest {
    var headers = ["Host": host]
    headers["Origin"] = origin
    return HTTPRequest(method: "POST", headers: headers, path: "/mcp")
  }
}

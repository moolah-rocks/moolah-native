import Foundation
import MCP
import Testing

@testable import MoolahMCP

struct MCPProtocolAdapterTests {
  @Test
  func negotiatesProtocolAndAdvertisesOnlyTools() async throws {
    let response = try await MCPProtocolAdapter.respond(
      to: request(
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#
      )
    )
    let json = try object(response)
    let result = try #require(json["result"] as? [String: Any])
    #expect(result["protocolVersion"] as? String == "2025-11-25")
    let capabilities = try #require(result["capabilities"] as? [String: Any])
    #expect(Set(capabilities.keys) == ["tools"])
    #expect(response.headers["MCP-Session-Id"] == nil)
  }

  @Test
  func handlesNotificationsAndRejectsGET() async throws {
    let notification = try await MCPProtocolAdapter.respond(
      to: request(
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
      )
    )
    #expect(notification.statusCode == 202)
    #expect(notification.bodyData == nil)
    let get = try await MCPProtocolAdapter.respond(to: HTTPRequest(method: "GET", path: "/mcp"))
    #expect(get.statusCode == 405)
  }

  @Test
  func validatesProtocolVersionAndContentType() async throws {
    var headers = Self.headers
    headers["MCP-Protocol-Version"] = "bogus"
    let version = try await MCPProtocolAdapter.respond(
      to: request(
        #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
        headers: headers
      )
    )
    #expect(version.statusCode == 400)
    headers = Self.headers
    headers["Content-Type"] = "text/plain"
    let contentType = try await MCPProtocolAdapter.respond(
      to: request(
        #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#,
        headers: headers
      )
    )
    #expect(contentType.statusCode == 415)
  }

  @Test
  func isolatesConcurrentClientsReusingRequestIDs() async throws {
    let responses = try await withThrowingTaskGroup(of: HTTPResponse.self) { group in
      for _ in 0..<16 {
        group.addTask {
          try await MCPProtocolAdapter.respond(
            to: request(
              #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#
            )
          )
        }
      }
      var values: [HTTPResponse] = []
      for try await value in group { values.append(value) }
      return values
    }
    #expect(responses.count == 16)
    for response in responses {
      #expect(try object(response)["id"] as? Int == 1)
    }
  }

  @Test
  func rejectsMalformedEnvelopesWithoutWaitingForAnUnroutableResponse() async throws {
    for json in [
      #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#,
      #"{"jsonrpc":"1.0","id":1,"method":"ping"}"#,
      #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#,
      #"[{"jsonrpc":"2.0","id":1,"method":"ping"}]"#,
    ] {
      let response = try await MCPProtocolAdapter.respond(to: request(json))
      #expect(response.statusCode == 400)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func deadlineCancelsToolWorkBeforeReturning() async throws {
    let probe = MCPQueryCancellationProbe()
    let response = try await MCPProtocolAdapter.respond(
      to: request(
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"probe","arguments":{}}}"#
      ),
      waitForDeadline: { await probe.waitUntilStarted() },
      call: { _ in try await probe.run() }
    )
    #expect(response.statusCode == 504)
    #expect(await probe.didCancel)
  }

  @Test(.timeLimit(.minutes(1)))
  func callerCancellationStopsToolWorkBeforeThrowing() async throws {
    let probe = MCPQueryCancellationProbe()
    let task = Task {
      try await MCPProtocolAdapter.respond(
        to: request(
          #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"probe","arguments":{}}}"#
        ),
        call: { _ in try await probe.run() }
      )
    }
    await probe.waitUntilStarted()
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(await probe.didCancel)
  }

  private static let headers = [
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
    "MCP-Protocol-Version": "2025-11-25",
  ]

  private func request(_ json: String, headers: [String: String] = Self.headers) -> HTTPRequest {
    HTTPRequest(method: "POST", headers: headers, body: Data(json.utf8), path: "/mcp")
  }

  private func object(_ response: HTTPResponse) throws -> [String: Any] {
    let data = try #require(response.bodyData)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
}

extension MCPProtocolAdapterTests {
  @Test
  func boundsStringRequestIDsBeforeDispatchAndReflection() async throws {
    for count in [128, 129] {
      let identifier = String(repeating: "x", count: count)
      let body = "{\"jsonrpc\":\"2.0\",\"id\":\"\(identifier)\",\"method\":\"ping\"}"
      let response = try await MCPProtocolAdapter.respond(to: request(body))
      #expect(response.statusCode == (count == 128 ? 200 : 400))
      #expect((response.bodyData?.count ?? 0) < 1024)
    }
  }
}

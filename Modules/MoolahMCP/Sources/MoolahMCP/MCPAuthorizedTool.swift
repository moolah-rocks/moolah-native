import Foundation
import MCP

/// SDK tool schema exposed without requiring application code to import the SDK.
public typealias MCPToolSchema = Tool
/// SDK JSON value used in validated tool arguments and results.
public typealias MCPToolValue = Value
/// SDK structured and text tool response.
public typealias MCPToolResult = CallTool.Result

/// A deliberately registered read handler, never reflection over the write automation surface.
public struct MCPAuthorizedTool: Sendable {
  let schema: Tool
  let scope: MCPReadScope
  let requiresProfile: Bool
  let handler: @Sendable (MCPToolInvocation) async throws -> CallTool.Result

  /// Registers a deliberately implemented read handler and its required scope.
  /// Profile-scoped tools require an explicit profile_id before handler invocation.
  /// Read-only annotations are enforced here; handlers must also preserve read-only behavior.
  /// - Parameters:
  ///   - schema: Explicit SDK schema for an implemented read tool.
  ///   - scope: Required permission, enforced on every call.
  ///   - requiresProfile: Whether the endpoint must parse and authorize profile_id.
  ///   - handler: Read-only argument validation and query implementation.
  public init(
    schema: Tool,
    scope: MCPReadScope,
    requiresProfile: Bool = true,
    handler: @escaping @Sendable (MCPToolInvocation) async throws -> CallTool.Result
  ) {
    self.schema = Tool(
      name: schema.name,
      title: schema.title,
      description: schema.description,
      inputSchema: schema.inputSchema,
      annotations: .init(
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false
      ),
      outputSchema: schema.outputSchema
    )
    self.scope = scope
    self.requiresProfile = requiresProfile
    self.handler = handler
  }
}

/// Per-call authorization and arguments supplied only after endpoint checks.
public struct MCPToolInvocation: Sendable {
  /// Captured credential context; revalidate before serialization after external awaits.
  public let context: MCPAuthorizationContext
  /// Explicit authorized profile, or nil only for a deliberately profile-independent tool.
  public let profileID: UUID?
  /// Untrusted JSON arguments; the registered handler must validate its complete input contract.
  public let arguments: [String: Value]
}

extension MCPAccessFailure {
  /// Safe, actionable client-facing text; never includes underlying errors or financial data.
  public var message: String {
    switch self {
    case .accessDenied:
      "This integration cannot access the requested data. Check its access in Moolah and try again."
    case .invalidFilter: "Check the query filters and try again."
    case .cursorExpired: "Restart this query without a cursor."
    case .queryLimit: "Four queries are already running. Try again when one finishes."
    case .rateLimited: "Too many requests. Try again in a minute."
    case .queryTimeout: "The query took too long. Narrow its date range or filters."
    case .queryCancelled: "The query was cancelled."
    case .resultTooLarge: "The result is too large. Use a smaller page or narrower filters."
    case .unavailable:
      "Moolah couldn’t access this profile. Confirm that it is available in Moolah, then try again."
    case .incompatible: "Update Moolah to open this profile."
    case .priceUnavailable:
      "A required price is unavailable. Check the requested asset and date, then try again."
    case .unsupported: "This query option is not supported. Remove it and try again."
    case .internalFailure: "Moolah couldn’t complete the query. Try again."
    }
  }

  func result() -> CallTool.Result {
    .init(
      content: [.text(text: "\(rawValue): \(message)", annotations: nil, _meta: nil)],
      structuredContent: .object([
        "error": .object(["code": .string(rawValue), "message": .string(message)])
      ]),
      isError: true
    )
  }
}

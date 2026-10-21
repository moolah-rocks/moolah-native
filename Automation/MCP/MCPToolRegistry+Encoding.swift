import Foundation
import MoolahMCP

extension MCPToolRegistry {
  func encode<Element: Codable & Sendable>(
    page: ReadQueryResponse<Element>,
    context: MCPAuthorizationContext,
    binding: MCPCursorBinding? = nil
  ) async throws -> MCPToolResult {
    let cursor: String?
    if let key = page.nextKey {
      guard let binding else { throw MCPAccessFailure.internalFailure }
      cursor = try cursors.encode(
        continuation: MCPCursorContinuation(
          key: JSONEncoder().encode(key),
          revision: page.metadata.localRevision
        ),
        binding: binding
      )
    } else {
      cursor = nil
    }
    return try await encode(
      MCPPageResult(
        metadata: page.metadata,
        items: page.items,
        nextCursor: cursor,
        hasMore: cursor != nil
      ),
      context: context
    )
  }

  func encode(_ value: some Encodable & Sendable, context: MCPAuthorizationContext) async throws
    -> MCPToolResult
  {
    // Authorization is checked before CPU serialization and again by the endpoint before return.
    try await grants.validate(context)
    try Task.checkCancellation()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(value)
    guard data.count <= 500_000 else { throw MCPAccessFailure.resultTooLarge }
    let structured = try JSONDecoder().decode(MCPToolValue.self, from: data)
    guard let text = String(bytes: data, encoding: .utf8) else {
      throw MCPAccessFailure.internalFailure
    }
    return try MCPToolResult(
      content: [.text(text: text, annotations: nil, _meta: nil)],
      structuredContent: structured
    )
  }
}

private struct MCPPageResult<Element: Encodable & Sendable>: Encodable, Sendable {
  let metadata: ReadQueryMetadata
  let items: [Element]
  let nextCursor: String?
  let hasMore: Bool
}

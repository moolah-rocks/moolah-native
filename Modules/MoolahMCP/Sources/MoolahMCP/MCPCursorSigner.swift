import CryptoKit
import Foundation

/// Cursors are authenticated capabilities for one grant revision, profile, tool and filter set.
/// The process-local signing key intentionally invalidates continuations after an app restart.
public struct MCPCursorSigner: Sendable {
  let key: SymmetricKey
  let uptime: @Sendable () -> TimeInterval

  /// Creates a process-local signing key using secure randomness.
  /// The injected clock must be monotonic seconds. Throws if secure randomness is unavailable.
  public init(
    uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) throws {
    key = SymmetricKey(data: try MCPSecureBytes.random(count: 32))
    self.uptime = uptime
  }

  /// - Returns: a signed continuation bound to the supplied authorization and validated filters.
  /// - Throws: for oversized fields or encoding failure. The token expires after 15 monotonic minutes.
  public func encode(
    continuation: MCPCursorContinuation,
    binding: MCPCursorBinding
  ) throws -> String {
    guard continuation.key.count <= 2048, continuation.revision.utf8.count <= 256,
      binding.tool.utf8.count <= 80, binding.filterDigest.count == 32
    else { throw MCPAccessFailure.cursorExpired }
    let payload = MCPCursorPayload(
      version: 1,
      binding: binding,
      continuation: continuation,
      expiresAtUptime: uptime() + 900
    )
    let data = try JSONEncoder().encode(payload)
    let signature = Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    let cursor = MCPSecureBytes.encoded(data) + "." + MCPSecureBytes.encoded(signature)
    guard cursor.utf8.count <= 8192 else { throw MCPAccessFailure.cursorExpired }
    return cursor
  }

  /// Authenticates a bounded cursor and returns its continuation only for the exact binding.
  /// - Throws: cursorExpired for malformed, altered, expired, cross-binding or pre-restart tokens.
  public func decode(
    _ cursor: String,
    binding: MCPCursorBinding
  ) throws -> MCPCursorContinuation {
    guard cursor.utf8.count <= 8192 else { throw MCPAccessFailure.cursorExpired }
    let pieces = cursor.split(separator: ".", omittingEmptySubsequences: false)
    guard pieces.count == 2,
      let data = MCPSecureBytes.decoded(String(pieces[0])),
      let signature = MCPSecureBytes.decoded(String(pieces[1])), signature.count == 32
    else { throw MCPAccessFailure.cursorExpired }
    let expected = Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    guard MCPSecureBytes.equal(signature, expected),
      let payload = try? JSONDecoder().decode(MCPCursorPayload.self, from: data),
      payload.version == 1, payload.expiresAtUptime > uptime(), payload.binding == binding,
      payload.continuation.key.count <= 2048, payload.continuation.revision.utf8.count <= 256
    else { throw MCPAccessFailure.cursorExpired }
    return payload.continuation
  }
}

/// Repository keyset and revision carried inside an authenticated, expiring cursor.
public struct MCPCursorContinuation: Codable, Equatable, Sendable {
  /// Opaque repository keyset encoding, limited to 2,048 bytes by the signer.
  public let key: Data
  /// Repository revision used to reject pages after relevant local changes.
  public let revision: String

  /// Packages a repository keyset and revision; encode enforces their size limits.
  public init(key: Data, revision: String) {
    self.key = key
    self.revision = revision
  }
}

/// Exact authorization and query identity required to reuse a continuation.
public struct MCPCursorBinding: Codable, Equatable, Sendable {
  let grantID: UUID
  let grantRevision: UUID
  let profileID: UUID
  let tool: String
  let filterDigest: Data

  /// Filter bytes must come from canonical encoding of validated filters, including ordering.
  public init(
    context: MCPAuthorizationContext,
    profileID: UUID,
    tool: String,
    canonicalFilters: Data
  ) {
    self.grantID = context.grantID
    self.grantRevision = context.revision
    self.profileID = profileID
    self.tool = tool
    self.filterDigest = Data(SHA256.hash(data: canonicalFilters))
  }
}

private struct MCPCursorPayload: Codable {
  let version: Int
  let binding: MCPCursorBinding
  let continuation: MCPCursorContinuation
  let expiresAtUptime: TimeInterval
}

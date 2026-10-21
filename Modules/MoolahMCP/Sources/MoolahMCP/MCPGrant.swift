import Foundation

/// Read permissions are explicit; transaction notes are deliberately absent from defaults.
public enum MCPReadScope: String, Codable, CaseIterable, Sendable {
  case profiles = "profiles:read"
  case accounts = "accounts:read"
  case transactions = "transactions:read"
  case categories = "categories:read"
  case earmarks = "earmarks:read"
  case summaries = "summaries:read"
  case transactionNotes = "transaction_notes:read"

  /// Read scopes offered by default, excluding the separately granted transaction notes.
  public static let standard: Set<Self> = Set(allCases).subtracting([.transactionNotes])
}

/// Device-local metadata. Neither this value nor listGrants exposes the token or its verifier.
public struct MCPGrant: Codable, Equatable, Sendable, Identifiable {
  /// Stable, non-secret credential identifier.
  public let id: UUID
  /// Local integration name chosen during creation.
  public let label: String
  /// Explicit profile allowlist; there is no current-profile fallback.
  public let profileIDs: Set<UUID>
  /// Explicit read permissions captured for this grant or context.
  public let scopes: Set<MCPReadScope>
  /// Wall-clock instant when the credential was created.
  public let createdAt: Date
  /// Optional absolute expiry; authorization rejects this instant and later.
  public let expiresAt: Date?
  /// Revocation timestamp, or nil until explicitly revoked.
  public var revokedAt: Date?
  /// Best-effort last authentication timestamp, persisted at most once per minute.
  public var lastUsedAt: Date?
}

/// Available only at creation; the caller must discard the secret after its one-time display.
public struct MCPCreatedCredential: Sendable {
  /// Non-secret metadata associated with the newly created token.
  public let grant: MCPGrant
  /// Recoverable bearer secret, returned only once; never persist or log this value.
  public let token: String
}

/// Only the credential validator constructs contexts; every tool checks its revision again.
public struct MCPAuthorizationContext: Sendable {
  /// Identifier of the validated credential; does not itself authorize access.
  public let grantID: UUID
  /// Explicit profile allowlist; there is no current-profile fallback.
  public let profileIDs: Set<UUID>
  /// Explicit read permissions captured for this grant or context.
  public let scopes: Set<MCPReadScope>
  let revision: UUID
}

/// Stable tool-error codes; transport authentication failures remain generic HTTP errors.
public enum MCPAccessFailure: String, Error, Sendable {
  case accessDenied = "ACCESS_DENIED"
  case invalidFilter = "INVALID_FILTER"
  case cursorExpired = "CURSOR_EXPIRED"
  case queryLimit = "QUERY_LIMIT"
  case rateLimited = "RATE_LIMITED"
  case queryTimeout = "QUERY_TIMEOUT"
  case queryCancelled = "QUERY_CANCELLED"
  case resultTooLarge = "RESULT_TOO_LARGE"
  case unavailable = "PROFILE_UNAVAILABLE"
  case incompatible = "PROFILE_INCOMPATIBLE"
  case priceUnavailable = "PRICE_UNAVAILABLE"
  case unsupported = "UNSUPPORTED"
  case internalFailure = "QUERY_FAILED"
}

struct MCPStoredGrant: Codable, Sendable {
  let grant: MCPGrant
  let revision: UUID
  let verifier: Data
}

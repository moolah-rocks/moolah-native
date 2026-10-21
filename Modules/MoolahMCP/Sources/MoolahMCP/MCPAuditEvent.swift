import Foundation

/// Deliberately bounded diagnostic metadata; arguments, results and secrets have no field here.
public struct MCPAuditEvent: Codable, Sendable {
  /// Wall-clock instant the call completed, used for seven-day local retention.
  public let timestamp: Date
  /// Non-secret credential identity, without label or verifier.
  public let credentialID: UUID
  /// Registered tool name, or the fixed value unknown for an unregistered request.
  public let tool: String
  /// Parsed profile UUID only; never an entity name or query filter.
  public let profileID: UUID?
  /// Nonnegative elapsed monotonic seconds.
  public let duration: TimeInterval
  /// Stable outcome code without underlying error messages.
  public let outcome: String

  /// Creates metadata without accepting arguments or financial data.
  public init(
    timestamp: Date,
    credentialID: UUID,
    tool: String,
    profileID: UUID?,
    duration: TimeInterval,
    outcome: String
  ) {
    self.timestamp = timestamp
    self.credentialID = credentialID
    self.tool = tool
    self.profileID = profileID
    self.duration = duration
    self.outcome = outcome
  }
}

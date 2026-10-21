import Foundation

extension MCPGrantStore {
  /// Creates a named credential for explicitly selected profiles and scopes.
  ///
  /// - Returns: the secret once; callers must discard it after display. Notes are off by default.
  /// - Throws: on invalid metadata, capacity, randomness or persistence failure; no grant is published on failure.
  /// - Parameters:
  ///   - label: Local integration name, trimmed and bounded to 120 UTF-8 bytes.
  ///   - profileIDs: Explicit nonempty profile allowlist.
  ///   - scopes: Explicit nonempty read permissions; notes require separate opt-in.
  ///   - expiresAt: Optional expiry later than creation.
  public func create(
    label: String,
    profileIDs: Set<UUID>,
    scopes: Set<MCPReadScope> = MCPReadScope.standard,
    expiresAt: Date? = nil
  ) throws -> MCPCreatedCredential {
    guard records.count < 100 else { throw MCPStorageFailure.grantLimit }
    let grant = MCPGrant(
      id: UUID(),
      label: label.trimmingCharacters(in: .whitespacesAndNewlines),
      profileIDs: profileIDs,
      scopes: scopes,
      createdAt: now(),
      expiresAt: expiresAt
    )
    try Self.validateMetadata(grant)
    let secret = try MCPSecureBytes.encoded(MCPSecureBytes.random(count: 32))
    let token = "moolah_\(grant.id.uuidString.lowercased()).\(secret)"
    try commit(
      MCPStoredGrant(grant: grant, revision: UUID(), verifier: MCPSecureBytes.verifier(token))
    )
    return MCPCreatedCredential(grant: grant, token: token)
  }

  /// Rotation is a new credential, followed by explicit revocation of the old credential.
  /// Permission edits invalidate contexts/cursors and cancel the old permission's active work.
  public func updatePermissions(
    id: UUID,
    profileIDs: Set<UUID>,
    scopes: Set<MCPReadScope>
  ) throws {
    guard let record = records[id], record.grant.revokedAt == nil else {
      throw MCPStorageFailure.invalidGrant
    }
    let previous = record.grant
    let grant = MCPGrant(
      id: id,
      label: previous.label,
      profileIDs: profileIDs,
      scopes: scopes,
      createdAt: previous.createdAt,
      expiresAt: previous.expiresAt,
      lastUsedAt: previous.lastUsedAt
    )
    try Self.validateMetadata(grant)
    try commit(MCPStoredGrant(grant: grant, revision: UUID(), verifier: record.verifier))
    cancelQueries(grantID: id)
  }

  /// Persists immediate revocation and cancels active work for this credential.
  /// - Throws: on an unknown identifier or persistence failure; repeated revocation is harmless.
  public func revoke(id: UUID) throws {
    guard let record = records[id] else { throw MCPStorageFailure.invalidGrant }
    if record.grant.revokedAt != nil { return }
    var grant = record.grant
    grant.revokedAt = now()
    try commit(MCPStoredGrant(grant: grant, revision: UUID(), verifier: record.verifier))
    requestTimes.removeValue(forKey: id)
    cancelQueries(grantID: id)
  }

  /// Removing audit-free revoked metadata recovers capacity without invalidating active grants.
  public func removeRevoked(id: UUID) throws {
    guard let record = records[id], record.grant.revokedAt != nil else {
      throw MCPStorageFailure.invalidGrant
    }
    var updated = records
    updated.removeValue(forKey: id)
    try persist(updated)
  }

}

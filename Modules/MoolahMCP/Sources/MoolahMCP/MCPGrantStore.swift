import Foundation

/// Serializes credential changes, admission and active query cancellation. Persistence failures
/// leave the previous complete grant set intact; an unreadable store never becomes an empty one.
public actor MCPGrantStore {
  // MARK: - Cross-extension internals

  // Management and QueryExecution share this actor's immutable dependencies and state.
  let persistence: any MCPSecretPersisting
  let now: @Sendable () -> Date
  let uptime: @Sendable () -> TimeInterval
  var records: [UUID: MCPStoredGrant]
  var requestTimes: [UUID: [TimeInterval]] = [:]
  var activeQueries: [UUID: [UUID: MCPActiveQuery]] = [:]
  var acceptingQueries = true
  var endpointOwner: UUID?

  /// The factory's explicit executor boundary keeps initial Keychain I/O off the caller.
  @concurrent
  public static func open(
    persistence: any MCPSecretPersisting,
    now: @escaping @Sendable () -> Date = { Date() },
    uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
  ) async throws -> MCPGrantStore {
    let data = try persistence.readData()
    return try MCPGrantStore(persistence: persistence, data: data, now: now, uptime: uptime)
  }

  private init(
    persistence: any MCPSecretPersisting,
    data: Data?,
    now: @escaping @Sendable () -> Date,
    uptime: @escaping @Sendable () -> TimeInterval
  ) throws {
    self.persistence = persistence
    self.now = now
    self.uptime = uptime
    if let data {
      guard data.count <= 1_048_576,
        let archive = try? JSONDecoder().decode(MCPGrantArchive.self, from: data),
        archive.version == 1, archive.records.count <= 100
      else { throw MCPStorageFailure.invalidData }
      var loaded: [UUID: MCPStoredGrant] = [:]
      for record in archive.records {
        guard record.verifier.count == 32, loaded[record.grant.id] == nil else {
          throw MCPStorageFailure.invalidData
        }
        try Self.validateMetadata(record.grant)
        loaded[record.grant.id] = record
      }
      records = loaded
    } else {
      records = [:]
    }
  }

  /// - Returns: bounded local metadata for Settings, including revoked and expired grants; never secrets.
  public func listGrants() -> [MCPGrant] {
    records.values.map(\.grant).sorted { $0.createdAt < $1.createdAt }
  }

  /// Checks the bearer again after HTTP body collection; no cached transport session is authority.
  public func authenticate(header: String?) throws -> MCPAuthorizationContext? {
    guard let token = Self.bearer(header), let id = Self.credentialID(token),
      let record = records[id], isCurrent(record),
      MCPSecureBytes.equal(MCPSecureBytes.verifier(token), record.verifier)
    else { return nil }
    try touch(record)
    return MCPAuthorizationContext(
      grantID: id,
      profileIDs: record.grant.profileIDs,
      scopes: record.grant.scopes,
      revision: record.revision
    )
  }

  /// Charge every authenticated HTTP message, including discovery, before collecting its body.
  public func admit(header: String?, endpointOwner: UUID? = nil) throws -> MCPAuthorizationContext?
  {
    try validateEndpoint(owner: endpointOwner)
    guard let context = try authenticate(header: header) else { return nil }
    let tick = uptime()
    var times = requestTimes[context.grantID] ?? []
    times.removeAll { tick - $0 >= 60 }
    guard times.count < 60 else { throw MCPAccessFailure.rateLimited }
    times.append(tick)
    requestTimes[context.grantID] = times
    return context
  }

  /// Rechecks the captured revision against the current, unexpired, unrevoked grant.
  /// Optional scope and profile further restrict the required authorization.
  /// - Throws: accessDenied for any stale context, missing permission or unauthorized profile.
  public func validate(
    _ context: MCPAuthorizationContext,
    scope: MCPReadScope? = nil,
    profileID: UUID? = nil
  ) throws {
    guard let record = records[context.grantID], record.revision == context.revision,
      isCurrent(record),
      scope.map({ record.grant.scopes.contains($0) }) ?? true,
      profileID.map({ record.grant.profileIDs.contains($0) }) ?? true
    else { throw MCPAccessFailure.accessDenied }
  }
}

extension MCPGrantStore {
  func commit(_ record: MCPStoredGrant) throws {
    var updated = records
    updated[record.grant.id] = record
    try persist(updated)
  }

  func persist(_ updated: [UUID: MCPStoredGrant]) throws {
    let archive = MCPGrantArchive(version: 1, records: Array(updated.values))
    let data = try JSONEncoder().encode(archive)
    guard data.count <= 1_048_576 else { throw MCPStorageFailure.grantLimit }
    try persistence.writeData(data)
    records = updated
  }

  func isCurrent(_ record: MCPStoredGrant) -> Bool {
    record.grant.revokedAt == nil && (record.grant.expiresAt.map { now() < $0 } ?? true)
  }

  static func validateMetadata(_ grant: MCPGrant) throws {
    guard !grant.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      grant.label.utf8.count <= 120,
      !grant.profileIDs.isEmpty, grant.profileIDs.count <= 500, !grant.scopes.isEmpty,
      grant.expiresAt.map({ $0 > grant.createdAt }) ?? true
    else { throw MCPStorageFailure.invalidGrant }
  }

  private func touch(_ record: MCPStoredGrant) throws {
    if let previous = record.grant.lastUsedAt, now().timeIntervalSince(previous) < 60 { return }
    var grant = record.grant
    grant.lastUsedAt = now()
    try commit(MCPStoredGrant(grant: grant, revision: record.revision, verifier: record.verifier))
  }

  private static func bearer(_ header: String?) -> String? {
    guard let header, header.utf8.count <= 180 else { return nil }
    let fields = header.split(separator: " ", omittingEmptySubsequences: false)
    guard fields.count == 2, fields[0].lowercased() == "bearer" else { return nil }
    return String(fields[1])
  }

  private static func credentialID(_ token: String) -> UUID? {
    let fields = token.split(separator: ".", omittingEmptySubsequences: false)
    guard fields.count == 2, fields[0].hasPrefix("moolah_"),
      let id = UUID(uuidString: String(fields[0].dropFirst(7))),
      let secret = MCPSecureBytes.decoded(String(fields[1])), secret.count == 32,
      token == "moolah_\(id.uuidString.lowercased()).\(fields[1])"
    else { return nil }
    return id
  }
}

struct MCPGrantArchive: Codable {
  let version: Int
  let records: [MCPStoredGrant]
}

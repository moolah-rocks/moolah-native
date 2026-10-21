import Foundation
import MoolahMCP

extension MCPServerController {
  func openGrantStore() async throws -> MCPGrantStore {
    if let grantStore { return grantStore }
    let store = try await MCPGrantStore.open(persistence: persistence, now: now)
    try Task.checkCancellation()
    grantStore = store
    return store
  }

  func startListener() async throws {
    do {
      try await startOwnedListener()
    } catch {
      await stopListener(keepFailure: true)
      state = .failed
      throw error
    }
  }

  private func startOwnedListener() async throws {
    guard listenerTask == nil, !isShuttingDown else { return }
    let generation = UUID()
    listenerGeneration = generation
    state = .starting
    let policy = try MCPRequestPolicy(port: port)
    let store = try await openGrantStore()
    try await refreshMetadata()
    await reconcileLeases()
    try Task.checkCancellation()
    let history = history
    let endpoint = try MCPAuthenticatedEndpoint(
      policy: policy,
      grants: store,
      tools: makeTools(store),
      audit: { try await history.append($0) }
    )
    // Suppress App Nap for query responsiveness without preventing idle system sleep.
    activity = ProcessInfo.processInfo.beginActivity(
      options: [.userInitiatedAllowingIdleSystemSleep],
      reason: "Serving local read-only Moolah integrations"
    )
    let readiness = launchListener(endpoint: endpoint, generation: generation)
    var iterator = readiness.makeAsyncIterator()
    guard await iterator.next() == true, listenerGeneration == generation else {
      throw MCPServerFailure.listener
    }
    maintenanceTask = Task { [weak self] in
      do {
        while true {
          try await Task.sleep(for: .seconds(30))
          try Task.checkCancellation()
          self?.refresh()
        }
      } catch { return }
    }
  }

  private func launchListener(
    endpoint: MCPAuthenticatedEndpoint,
    generation: UUID
  ) -> AsyncStream<Bool> {
    let readiness = AsyncStream<Bool>.makeStream()
    listenerTask = Task { [weak self] in
      defer { readiness.continuation.finish() }
      do {
        try await endpoint.run { [weak self] in
          await self?.didStartListening(generation: generation)
          readiness.continuation.yield(true)
        }
      } catch is CancellationError { return } catch {
        await self?.listenerFailed(generation: generation)
      }
    }
    return readiness.stream
  }

  private func didStartListening(generation: UUID) {
    guard listenerGeneration == generation, isEnabled, !isShuttingDown else { return }
    state = .running
  }

  func listenerFailed(generation: UUID) async {
    guard listenerGeneration == generation else { return }
    listenerGeneration = nil
    state = .failed
    errorMessage =
      "Moolah couldn’t start the local listener. Check that the port is free, then turn MCP off and on."
    // Endpoint.run has already drained its queries before reporting this failure.
    maintenanceTask?.cancel()
    await maintenanceTask?.value
    maintenanceTask = nil
    listenerTask = nil
    for id in leasedProfiles { sessions.releaseReadSession(profileID: id, owner: leaseOwner) }
    leasedProfiles = []
    readiness = [:]
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil
  }

  func stopListener(keepFailure: Bool = false) async {
    listenerGeneration = nil
    maintenanceTask?.cancel()
    await maintenanceTask?.value
    maintenanceTask = nil
    listenerTask?.cancel()
    await listenerTask?.value
    listenerTask = nil
    for id in leasedProfiles { sessions.releaseReadSession(profileID: id, owner: leaseOwner) }
    leasedProfiles = []
    readiness = [:]
    if let activity { ProcessInfo.processInfo.endActivity(activity) }
    activity = nil
    if !keepFailure { state = .stopped }
  }

  func refreshMetadata() async throws {
    if let grantStore { grants = await grantStore.listGrants() }
    do { auditEntries = try await history.entries() } catch { throw MCPServerFailure.auditRead }
  }

  func reconcileLeases() async {
    guard let generation = listenerGeneration, isEnabled else { return }
    let instant = now()
    let active = grants.filter {
      $0.revokedAt == nil && ($0.expiresAt.map { $0 > instant } ?? true)
    }
    let desired = Set(active.flatMap(\.profileIDs))
    for id in leasedProfiles.subtracting(desired) {
      sessions.releaseReadSession(profileID: id, owner: leaseOwner)
      leasedProfiles.remove(id)
      readiness.removeValue(forKey: id)
    }
    readiness = readiness.filter { desired.contains($0.key) }
    for id in desired.sorted(by: { $0.uuidString < $1.uuidString }) {
      guard listenerGeneration == generation else { return }
      await updateReadiness(profileID: id, generation: generation)
    }
  }

  private func updateReadiness(profileID id: UUID, generation: UUID) async {
    do {
      try Task.checkCancellation()
      guard listenerGeneration == generation else { return }
      guard canResumeAccess(profileID: id) else { return }
      guard try await acquireLease(profileID: id, generation: generation) else { return }
      _ = try await sessions.readAccess(profileID: id)
      guard listenerGeneration == generation else { return }
      readiness[id] = "Ready · sync freshness unknown"
    } catch ReadQueryError.profileIncompatible {
      guard listenerGeneration == generation else { return }
      sessions.releaseReadSession(profileID: id, owner: leaseOwner)
      readiness[id] = "Update Moolah to open this profile"
      leasedProfiles.remove(id)
    } catch is CancellationError {
      return
    } catch {
      guard listenerGeneration == generation else { return }
      if sessions.sessions[id]?.authStore.state == .signedOut { signedOutProfiles.insert(id) }
      sessions.releaseReadSession(profileID: id, owner: leaseOwner)
      leasedProfiles.remove(id)
      readiness[id] = "Unavailable · check this profile in Moolah"
    }
  }

  private func acquireLease(profileID id: UUID, generation: UUID) async throws -> Bool {
    if leasedProfiles.contains(id) { return true }
    _ = try await sessions.acquireReadSession(profileID: id, owner: leaseOwner)
    guard listenerGeneration == generation, !Task.isCancelled else {
      sessions.releaseReadSession(profileID: id, owner: leaseOwner)
      return false
    }
    leasedProfiles.insert(id)
    return true
  }

  private func canResumeAccess(profileID id: UUID) -> Bool {
    guard signedOutProfiles.contains(id) else { return true }
    guard let existing = sessions.sessions[id], case .signedIn = existing.authStore.state else {
      readiness[id] =
        "Access paused after sign-out. Open this profile in Moolah and sign in to resume access."
      return false
    }
    signedOutProfiles.remove(id)
    return true
  }

  static func message(for error: any Error) -> String {
    switch error {
    case MCPServerFailure.auditRead:
      "Moolah couldn’t read local activity history. Clear activity history in MCP settings, then try again."
    case MCPServerFailure.auditClear:
      "Moolah couldn’t clear local activity history. Check that your Mac has available storage, then try again."
    case MCPServerFailure.listener:
      "Moolah couldn’t start the local listener. Check that the port is free, then turn MCP off and on."
    case MCPConfigurationError.invalidEndpoint:
      "Choose a port from 1024 to 65535."
    case MCPStorageFailure.grantLimit:
      "The integration limit was reached. Remove a revoked integration, then try again."
    case MCPStorageFailure.invalidGrant:
      "Enter a name and select at least one profile and permission. Check the expiry date, then try again."
    default:
      "Moolah couldn’t save or load integration settings. Check Keychain access and try again."
    }
  }
}

enum MCPServerFailure: Error { case listener, auditRead, auditClear }

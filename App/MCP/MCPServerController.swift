import Foundation
import MoolahMCP
import Observation

/// App-scoped listener ownership; Settings and windows only observe this single instance.
@MainActor
@Observable
final class MCPServerController {
  enum State: Equatable {
    case stopped
    case starting
    case running
    case failed
  }

  let clipboard = MCPCredentialClipboard()
  let sessions: SessionManager
  let preferences: MCPServerPreferences
  let persistence: any MCPSecretPersisting
  let history: MCPAuditHistory
  let now: @Sendable () -> Date
  let makeTools: @Sendable (MCPGrantStore) throws -> [MCPAuthorizedTool]
  var isEnabled: Bool
  var port: Int
  var state: State = .stopped
  var errorMessage: String?
  var grants: [MCPGrant] = []
  var readiness: [UUID: String] = [:]
  var auditEntries: [MCPAuditEvent] = []
  var createdCredential: MCPCreatedCredential?
  var isBusy = false

  @ObservationIgnored var grantStore: MCPGrantStore?
  @ObservationIgnored var foregroundRevision = UUID()
  @ObservationIgnored var commandTask: Task<Void, Never>?
  @ObservationIgnored var listenerGeneration: UUID?
  @ObservationIgnored var listenerTask: Task<Void, Never>?
  @ObservationIgnored var auditStartupTask: Task<Void, Never>?
  @ObservationIgnored var auditMaintenanceTask: Task<Void, Never>?
  @ObservationIgnored var maintenanceTask: Task<Void, Never>?
  @ObservationIgnored var activity: (any NSObjectProtocol)?
  @ObservationIgnored var leasedProfiles: Set<UUID> = []
  @ObservationIgnored let leaseOwner = UUID()
  @ObservationIgnored var isShuttingDown = false

  init(
    sessions: SessionManager,
    preferences: MCPServerPreferences,
    persistence: any MCPSecretPersisting,
    history: MCPAuditHistory,
    now: @escaping @Sendable () -> Date = { Date() },
    makeTools: @escaping @Sendable (MCPGrantStore) throws -> [MCPAuthorizedTool] = { _ in [] }
  ) {
    self.sessions = sessions
    self.preferences = preferences
    self.persistence = persistence
    self.history = history
    self.now = now
    self.makeTools = makeTools
    isEnabled = preferences.isEnabled
    port = preferences.port
  }

  var endpoint: String { "http://127.0.0.1:\(port)/mcp" }

  var statusText: String {
    switch state {
    case .stopped: "Stopped"
    case .starting: "Starting…"
    case .running: "Listening on this Mac"
    case .failed: "Unable to start"
    }
  }

  var readinessIDs: [UUID] { readiness.keys.sorted { $0.uuidString < $1.uuidString } }

  var readinessEmptyMessage: String {
    if !isEnabled { return "Turn on MCP to check profile readiness." }
    if state == .failed {
      return "The listener is unavailable. Check the MCP status, then try again."
    }
    if state == .starting { return "Preparing profiles…" }
    if !grants.isEmpty, !grants.contains(where: { $0.revokedAt == nil && !isExpired($0) }) {
      return "No integrations have active access. Create a replacement or a new integration."
    }
    return "No profiles are available to MCP. Create an integration or edit its access to add one."
  }

  func isExpired(_ grant: MCPGrant) -> Bool { grant.expiresAt.map { $0 <= now() } ?? false }

  /// Called once by app composition, never by a profile-window appearance callback.
  func startIfEnabled() {
    startAuditMaintenance()
    guard isEnabled else { return }
    perform { try await $0.startListener() }
  }

  func loadSettings() {
    perform { controller in
      _ = try await controller.openGrantStore()
      try await controller.refreshMetadata()
    }
  }

  func applyPort(_ text: String) {
    configure(enabled: isEnabled, port: Int(text) ?? 0)
  }

  func configure(enabled: Bool, port: Int) {
    perform { controller in
      _ = try MCPRequestPolicy(port: port)
      await controller.stopListener()
      controller.preferences.port = port
      controller.preferences.isEnabled = enabled
      controller.port = port
      controller.isEnabled = enabled
      if enabled { try await controller.startListener() }
    }
  }

  func refresh() {
    perform { controller in
      try await controller.refreshMetadata()
      if controller.isEnabled { await controller.reconcileLeases() }
    }
  }

  func dismissCredential() {
    createdCredential = nil
  }

  func clearHistory() {
    perform { controller in
      do { try await controller.history.clear() } catch { throw MCPServerFailure.auditClear }
      controller.auditEntries = []
    }
  }

  /// All mutations serialize through one owned task; Settings cannot race credential edits.
  func perform(_ operation: @escaping @MainActor (MCPServerController) async throws -> Void) {
    guard commandTask == nil, !isShuttingDown else { return }
    foregroundRevision = UUID()
    isBusy = true
    errorMessage = nil
    commandTask = Task {
      defer {
        foregroundRevision = UUID()
        isBusy = false
        commandTask = nil
      }
      do { try await operation(self) } catch is CancellationError {
        return
      } catch {
        errorMessage = Self.message(for: error)
        if isEnabled, listenerTask == nil { state = .failed }
      }
    }
  }

  func shutdown() async {
    isShuttingDown = true
    foregroundRevision = UUID()
    auditStartupTask?.cancel()
    auditMaintenanceTask?.cancel()
    commandTask?.cancel()
    await commandTask?.value
    await stopListener()
    await auditStartupTask?.value
    await auditMaintenanceTask?.value
    auditStartupTask = nil
    auditMaintenanceTask = nil
    createdCredential = nil
    clipboard.clearIfOwned()
  }
}

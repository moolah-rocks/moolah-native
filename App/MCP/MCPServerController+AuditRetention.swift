import Foundation

extension MCPServerController {
  /// Expired metadata is purged at every app launch and hourly while running, even with MCP off.
  /// This touches only the local audit archive; it never opens Keychain or a listening socket.
  func startAuditMaintenance() {
    guard auditMaintenanceTask == nil, !isShuttingDown else { return }
    let startup = Task { [weak self] in
      guard let self else { return }
      await pruneHistory()
    }
    auditStartupTask = startup
    auditMaintenanceTask = Task { [weak self] in
      await startup.value
      do {
        while true {
          try await Task.sleep(for: .seconds(3600))
          try Task.checkCancellation()
          await self?.pruneHistory()
        }
      } catch { return }
    }
  }

  /// Background diagnostics cannot overwrite a foreground command that overlapped this read.
  func pruneHistory(beforePublishing: @Sendable () async -> Void = {}) async {
    let revision = foregroundRevision
    let failed: Bool
    do {
      _ = try await history.entries()
      failed = false
    } catch is CancellationError { return } catch {
      failed = true
    }
    await beforePublishing()
    guard revision == foregroundRevision, !isBusy, !isShuttingDown else { return }
    let message = Self.message(for: MCPServerFailure.auditRead)
    if failed { errorMessage = message } else if errorMessage == message { errorMessage = nil }
  }
}

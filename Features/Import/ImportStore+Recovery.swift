import Foundation

extension ImportStore {
  func dismissPending(id: UUID) async {
    do {
      try await staging.dismiss(pendingId: id)
      await reloadStagingLists()
    } catch {
      logger.error("Dismiss pending failed: \(error.localizedDescription)")
    }
  }

  func dismissFailed(id: UUID) async {
    do {
      try await staging.dismiss(failedId: id)
      await reloadStagingLists()
    } catch {
      logger.error("Dismiss failed failed: \(error.localizedDescription)")
    }
  }

  /// Retry a failed file from the durable staged copy.
  @discardableResult
  func retryFailed(id: UUID) async -> ImportSessionResult {
    await enqueueImport {
      await self.performRetryFailed(id: id)
    }
  }

  private func performRetryFailed(id: UUID) async -> ImportSessionResult {
    do {
      guard let record = try await staging.failedFiles().first(where: { $0.id == id })
      else {
        return .failed(message: "Failed file not found")
      }
      let bytes = try await staging.data(forFailedId: id)
      guard !Task.isCancelled else { return .cancelled }
      let completion = Task { @MainActor in
        let result = await self.performIngest(
          data: bytes,
          source: .reingestFromSetup(
            filename: record.originalFilename, sourceURL: nil))
        try await self.staging.dismiss(failedId: id)
        await self.reloadStagingLists()
        return result
      }
      return try await completion.value
    } catch {
      logger.error("retryFailed failed: \(error.localizedDescription)")
      return .failed(message: "Moolah couldn’t retry this file.")
    }
  }

  /// Complete a Needs Setup file with the confirmed profile.
  @discardableResult
  func finishSetup(pendingId: UUID, profile: CSVImportProfile) async -> ImportSessionResult {
    await enqueueImport {
      await self.performFinishSetup(pendingId: pendingId, profile: profile)
    }
  }

  private func performFinishSetup(
    pendingId: UUID, profile: CSVImportProfile
  ) async -> ImportSessionResult {
    do {
      let pendingRecord = try await staging.pendingFiles().first { $0.id == pendingId }
      let originalFilename = pendingRecord?.originalFilename ?? "setup-\(pendingId.uuidString)"
      let sourceURL = resolveSourceURL(from: pendingRecord?.sourceBookmark)
      let bytes = try await staging.data(for: pendingId)
      guard !Task.isCancelled else { return .cancelled }
      let completion = Task { @MainActor in
        _ = try await self.backend.csvImportProfiles.create(profile)
        let result = await self.performIngest(
          data: bytes,
          source: .reingestFromSetup(
            filename: originalFilename, sourceURL: sourceURL))
        try await self.staging.dismiss(pendingId: pendingId)
        await self.reloadStagingLists()
        return result
      }
      return try await completion.value
    } catch {
      logger.error("finishSetup failed: \(error.localizedDescription)")
      return .failed(message: "Moolah couldn’t finish setting up this import.")
    }
  }

  private func resolveSourceURL(from bookmark: Data?) -> URL? {
    guard let bookmark else { return nil }
    var isStale = false
    #if os(macOS)
      let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
      let options: URL.BookmarkResolutionOptions = []
    #endif
    do {
      return try URL(
        resolvingBookmarkData: bookmark,
        options: options,
        relativeTo: nil,
        bookmarkDataIsStale: &isStale)
    } catch {
      logger.error("bookmark resolution failed: \(error.localizedDescription)")
      return nil
    }
  }
}

extension ImportStore {
  /// Serializes every import entry point without rejecting a source that may
  /// not be delivered again (folder events, extension inbox payloads, or a
  /// staged retry). Each caller awaits its own result while the tail keeps the
  /// next operation behind the current one.
  func enqueueImport(
    operation: @escaping @MainActor () async -> ImportSessionResult
  ) async -> ImportSessionResult {
    importQueueGeneration &+= 1
    let generation = importQueueGeneration
    let previous = importQueueTail
    let resultTask = Task { @MainActor in
      await previous?.value
      guard !Task.isCancelled else { return ImportSessionResult.cancelled }
      return await operation()
    }
    importQueueTail = Task { @MainActor [weak self] in
      _ = await resultTask.value
      guard self?.importQueueGeneration == generation else { return }
      self?.importQueueTail = nil
    }
    return await withTaskCancellationHandler {
      await resultTask.value
    } onCancel: {
      resultTask.cancel()
    }
  }
}

import Foundation

extension ImportStore {
  /// Whether a URL has a file type accepted by the CSV import entry points.
  nonisolated static func supportsImportFile(_ url: URL) -> Bool {
    let fileExtension = url.pathExtension.lowercased()
    return fileExtension.isEmpty || fileExtension == "csv" || fileExtension == "txt"
  }

  /// Reads dropped files and sends them through the shared import pipeline.
  func ingestDroppedFiles(
    _ urls: [URL],
    forcedAccountId: UUID? = nil
  ) async -> ImportFileIngestReport {
    await ingestFiles(urls) { url, didStartSecurityScope in
      _ = didStartSecurityScope
      return .droppedFile(url: url, forcedAccountId: forcedAccountId)
    }
  }

  /// Reads files selected through the system file picker and sends them
  /// through the shared import pipeline.
  func ingestPickedFiles(_ urls: [URL]) async -> ImportFileIngestReport {
    await ingestFiles(urls) { url, didStartSecurityScope in
      .pickedFile(url: url, securityScoped: didStartSecurityScope)
    }
  }

}

extension ImportStore {
  private func ingestFiles(
    _ urls: [URL],
    source: (URL, Bool) -> ImportSource
  ) async -> ImportFileIngestReport {
    var acceptedFileCount = 0
    var issues: [String] = []

    for url in urls {
      guard !Task.isCancelled else { break }
      guard Self.supportsImportFile(url) else {
        issues.append(
          "\(url.lastPathComponent) isn’t a CSV or text file. Choose a CSV or text file.")
        continue
      }
      acceptedFileCount += 1
      if let issue = await ingestFile(url, source: source) {
        issues.append(issue)
      }
      guard !Task.isCancelled else { break }
    }

    if urls.isEmpty {
      issues.append("No files were selected. Choose a CSV or text file to import.")
    }
    return ImportFileIngestReport(
      acceptedFileCount: acceptedFileCount,
      issues: issues)
  }

  private func ingestFile(
    _ url: URL,
    source: (URL, Bool) -> ImportSource
  ) async -> String? {
    let didStartSecurityScope = url.startAccessingSecurityScopedResource()
    defer {
      if didStartSecurityScope { url.stopAccessingSecurityScopedResource() }
    }

    let data: Data
    do {
      data = try await Self.readFileData(at: url)
    } catch {
      return
        "Couldn’t read \(url.lastPathComponent). Check that the file is available, then try again."
    }
    guard !Task.isCancelled else { return nil }

    let result = await ingest(
      data: data,
      source: source(url, didStartSecurityScope))
    if case .failed(let message) = result {
      return
        "Couldn’t import \(url.lastPathComponent): \(message) "
        + "Review it under Failed Files, then try again."
    }
    if case .cancelled = result { return nil }
    return nil
  }

  @concurrent
  private static func readFileData(at url: URL) async throws -> Data {
    try Data(contentsOf: url)
  }
}

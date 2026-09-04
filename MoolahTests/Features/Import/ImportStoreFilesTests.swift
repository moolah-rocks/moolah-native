import Foundation
import Testing

@testable import Moolah

@Suite("ImportStore file facade")
@MainActor
struct ImportStoreFilesTests {
  private func makeStore() throws -> (ImportStore, URL) {
    let (backend, _) = try TestBackend.create()
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("import-store-files-\(UUID().uuidString)", isDirectory: true)
    let staging = try ImportStagingStore(directory: directory)
    return (
      ImportStore(
        backend: backend,
        staging: staging,
        transferDetection: TransferDetectionCoordinator(
          transactions: backend.transactions,
          suggestions: backend.transferSuggestions)),
      directory
    )
  }

  @Test("reports unsupported and unreadable files")
  func reportsFailures() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let unsupported = URL(fileURLWithPath: "/tmp/statement.pdf")
    let missing = URL(fileURLWithPath: "/tmp/missing-\(UUID().uuidString).csv")

    let report = await store.ingestDroppedFiles([unsupported, missing])

    #expect(report.acceptedFileCount == 1)
    #expect(report.issues.count == 2)
    #expect(
      report.userMessage?.contains(
        "statement.pdf isn’t a CSV or text file. Choose a CSV or text file.") == true)
    #expect(report.userMessage?.contains(missing.lastPathComponent) == true)
  }

  @Test("reads a supported file and hands it to the import pipeline")
  func ingestsSupportedFile() async throws {
    let (store, directory) = try makeStore()
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("statement.csv")
    let bytes = Data("date,description,debit,credit,balance\n1/1/2026,Coffee,5,,95".utf8)
    try bytes.write(to: fileURL)

    let report = await store.ingestDroppedFiles([fileURL])

    #expect(report.acceptedFileCount == 1)
    #expect(report.issues.isEmpty)
    #expect(store.pendingSetup.count == 1)
  }
}

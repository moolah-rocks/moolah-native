import Foundation
import Testing

@testable import ImportExtensionKit

@Suite("InboxWriter")
struct InboxWriterTests {

  private func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("inbox-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func samplePayload() -> ImportPayload {
    ImportPayload(
      schemaVersion: 1, sourceHost: "chase.com",
      sourceURL: "https://chase.com/x",
      capturedAt: Date(timeIntervalSince1970: 1_716_000_000),
      accountHint: "1234", currencyHint: "USD",
      rows: [ImportPayloadRow(date: "2026-05-29", amount: "1.00", description: "x")])
  }

  @Test("write then read returns the same payload")
  func writeReadRoundTrip() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = InboxWriter(rootDirectory: dir)
    let id = UUID()
    try writer.write(samplePayload(), id: id)
    let read = try writer.read(id: id)
    #expect(read == samplePayload())
  }

  @Test("delete removes the inbox file")
  func deleteRemovesFile() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = InboxWriter(rootDirectory: dir)
    let id = UUID()
    try writer.write(samplePayload(), id: id)
    try writer.delete(id: id)
    #expect(throws: InboxWriterError.self) { try writer.read(id: id) }
  }

  @Test("read of a missing id throws .notFound")
  func readMissingThrowsNotFound() {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = InboxWriter(rootDirectory: dir)
    do {
      _ = try writer.read(id: UUID())
      Issue.record("Expected throw")
    } catch let error as InboxWriterError {
      if case .notFound = error {} else { Issue.record("Expected .notFound, got \(error)") }
    } catch {
      Issue.record("Expected InboxWriterError, got \(error)")
    }
  }

  @Test("list returns all pending ids, newest first")
  func listOrdersNewestFirst() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = InboxWriter(rootDirectory: dir)
    let older = UUID()
    let newer = UUID()
    try writer.write(samplePayload(), id: older)
    Thread.sleep(forTimeInterval: 0.05)  // ensure mtimes differ
    try writer.write(samplePayload(), id: newer)
    let ids = try writer.list()
    #expect(ids == [newer, older])
  }

  @Test("read of truncated JSON throws and quarantines the file")
  func corruptFileQuarantines() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = InboxWriter(rootDirectory: dir)
    let id = UUID()
    let path = dir.appendingPathComponent("Inbox/\(id.uuidString).json")
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("not json".utf8).write(to: path)
    #expect(throws: InboxWriterError.self) { try writer.read(id: id) }
    let quarantined = dir.appendingPathComponent("Quarantine/\(id.uuidString).json")
    #expect(FileManager.default.fileExists(atPath: quarantined.path))
  }

  @Test("write uses an atomic replace")
  func writeAtomic() throws {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let writer = InboxWriter(rootDirectory: dir)
    let id = UUID()
    try writer.write(samplePayload(), id: id)
    // Re-write — must not throw, must replace cleanly.
    try writer.write(samplePayload(), id: id)
    _ = try writer.read(id: id)
  }
}

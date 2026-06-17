import Foundation
import Testing

@testable import Moolah

/// Class-based suite so `deinit` can deterministically remove the per-test
/// temp directory. Each `@Test` method runs on its own instance.
@Suite("CatalogDatabase")
final class CatalogDatabaseTests {
  private let tempDir: URL

  init() throws {
    tempDir = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  deinit {
    try? FileManager.default.removeItem(at: tempDir)
  }

  private func dbURL() -> URL {
    tempDir.appending(path: "catalog.sqlite")
  }

  private func schema(version: Int) -> [String] {
    CatalogDatabase.baseSchemaStatements(schemaVersion: version)
      + ["CREATE TABLE t(x TEXT) STRICT;"]
  }

  private func open(version: Int) throws -> CatalogDatabase {
    try CatalogDatabase.open(
      dbURL: dbURL(),
      schemaVersion: version,
      schemaStatements: schema(version: version))
  }

  @Test
  func opensFreshDatabaseWithEmptyMeta() throws {
    let database = try open(version: 1)
    defer { database.close() }

    #expect(try database.readSchemaVersion() == 1)
    #expect(database.readLastFetched() == nil)
    #expect(database.readEtag(key: "coins") == nil)
  }

  @Test
  func roundTripsLastFetched() throws {
    let database = try open(version: 1)
    defer { database.close() }

    let now = Date()
    try database.writeLastFetched(now)
    let read = try #require(database.readLastFetched())
    #expect(abs(read.timeIntervalSince(now)) < 0.001)
  }

  @Test
  func roundTripsEtagAndClearsWithNil() throws {
    let database = try open(version: 1)
    defer { database.close() }

    try database.writeEtag(key: "coins", value: "abc123")
    #expect(database.readEtag(key: "coins") == "abc123")

    try database.writeEtag(key: "coins", value: nil)
    #expect(database.readEtag(key: "coins") == nil)
  }

  @Test
  func schemaVersionMismatchDropsAndRecreates() throws {
    do {
      let database = try open(version: 1)
      try database.writeEtag(key: "coins", value: "stale")
      #expect(database.readEtag(key: "coins") == "stale")
      database.close()
    }

    let reopened = try open(version: 2)
    defer { reopened.close() }
    #expect(try reopened.readSchemaVersion() == 2)
    #expect(reopened.readEtag(key: "coins") == nil)
  }

  @Test
  func sameSchemaVersionPreservesData() throws {
    do {
      let database = try open(version: 1)
      try database.writeEtag(key: "coins", value: "kept")
      database.close()
    }

    let reopened = try open(version: 1)
    defer { reopened.close() }
    #expect(reopened.readEtag(key: "coins") == "kept")
  }

  @Test
  func execThrowsOnInvalidSQL() throws {
    let database = try open(version: 1)
    defer { database.close() }

    #expect(throws: CatalogError.self) {
      try database.exec("NOT SQL")
    }
  }
}

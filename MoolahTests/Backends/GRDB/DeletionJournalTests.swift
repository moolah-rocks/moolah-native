import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests for the `deletion_journal` table + `DeletionJournal` helper (issue
/// #1090) — record / clear / list / idempotent re-record — against a migrated
/// in-memory profile database.
@Suite("DeletionJournal storage")
struct DeletionJournalTests {
  private static let zone = "profile-AAAA"
  private static let date = Date(timeIntervalSince1970: 1_700_000_000)

  private func makeDatabase() throws -> DatabaseQueue {
    try ProfileDatabase.openInMemory()
  }

  @Test("a recorded intent is listed")
  func recordThenList() async throws {
    let database = try makeDatabase()
    try await database.write { database in
      try DeletionJournal.record(
        zoneName: Self.zone, recordName: "AccountRecord|1", recordType: "AccountRecord",
        at: Self.date, in: database)
    }
    let entries = try await database.read { try DeletionJournal.allEntries(in: $0) }
    #expect(entries.count == 1)
    #expect(entries.first?.zoneName == Self.zone)
    #expect(entries.first?.recordName == "AccountRecord|1")
    #expect(entries.first?.recordType == "AccountRecord")
  }

  @Test("clear removes only the matching (zone, recordName)")
  func clearRemovesMatch() async throws {
    let database = try makeDatabase()
    try await database.write { database in
      try DeletionJournal.record(
        zoneName: Self.zone, recordName: "A|1", recordType: "AccountRecord",
        at: Self.date, in: database)
      try DeletionJournal.record(
        zoneName: Self.zone, recordName: "A|2", recordType: "AccountRecord",
        at: Self.date, in: database)
      try DeletionJournal.clear(zoneName: Self.zone, recordName: "A|1", in: database)
    }
    let entries = try await database.read { try DeletionJournal.allEntries(in: $0) }
    #expect(entries.map(\.recordName) == ["A|2"])
  }

  @Test("re-recording the same key is idempotent (one row, replaced)")
  func reRecordIsIdempotent() async throws {
    let database = try makeDatabase()
    try await database.write { database in
      try DeletionJournal.record(
        zoneName: Self.zone, recordName: "A|1", recordType: "AccountRecord",
        at: Self.date, in: database)
      // Same PK, later timestamp — must replace, not throw or duplicate.
      try DeletionJournal.record(
        zoneName: Self.zone, recordName: "A|1", recordType: "AccountRecord",
        at: Self.date.addingTimeInterval(60), in: database)
    }
    let entries = try await database.read { try DeletionJournal.allEntries(in: $0) }
    #expect(entries.count == 1)
    #expect(entries.first?.queuedAt == Self.date.addingTimeInterval(60).timeIntervalSince1970)
  }

  @Test("the same recordName in different zones are distinct entries")
  func zoneIsPartOfKey() async throws {
    let database = try makeDatabase()
    try await database.write { database in
      try DeletionJournal.record(
        zoneName: "profile-A", recordName: "A|1", recordType: "AccountRecord",
        at: Self.date, in: database)
      try DeletionJournal.record(
        zoneName: "profile-B", recordName: "A|1", recordType: "AccountRecord",
        at: Self.date, in: database)
    }
    let entries = try await database.read { try DeletionJournal.allEntries(in: $0) }
    #expect(entries.count == 2)
  }

  @Test("recordDataDeletion stores the sentinel zone; clearDataDeletion removes it")
  func dataDeletionHelpersUseSentinelZone() async throws {
    let database = try makeDatabase()
    try await database.write { database in
      try DeletionJournal.recordDataDeletion(
        recordName: "AccountRecord|1", recordType: "AccountRecord",
        at: Self.date, in: database)
    }
    let entry = try await database.read { try DeletionJournal.allEntries(in: $0).first }
    #expect(entry?.zoneName == DeletionJournal.profileDataSentinelZone)
    #expect(entry?.recordName == "AccountRecord|1")

    try await database.write { database in
      try DeletionJournal.clearDataDeletion(recordName: "AccountRecord|1", in: database)
    }
    let remaining = try await database.read { try DeletionJournal.allEntries(in: $0) }
    #expect(remaining.isEmpty)
  }

  @Test("clear batch removes all listed keys, leaves others")
  func clearBatch() async throws {
    let database = try makeDatabase()
    try await database.write { database in
      for index in 0..<3 {
        try DeletionJournal.record(
          zoneName: Self.zone, recordName: "A|\(index)", recordType: "AccountRecord",
          at: Self.date, in: database)
      }
      try DeletionJournal.clear(
        [(zoneName: Self.zone, recordName: "A|0"), (zoneName: Self.zone, recordName: "A|2")],
        in: database)
    }
    let entries = try await database.read { try DeletionJournal.allEntries(in: $0) }
    #expect(entries.map(\.recordName) == ["A|1"])
  }
}

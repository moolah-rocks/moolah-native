@preconcurrency import CloudKit
import Foundation
import Testing

@testable import Moolah

/// Pins the sentinel→real-zone resolution at the heart of the #1090 deletion
/// replay (PR-B): a per-profile data journal entry stores the `@profile-data`
/// sentinel and MUST resolve to that profile's real `profile-<id>` zone at
/// replay; an index entry resolves to the `profile-index` zone; mismatched
/// entries are never replayed into the wrong zone.
@Suite("Deletion replay — sentinel→real-zone resolution")
struct DeletionReplayResolutionTests {
  private let profileId = UUID()

  private func dataZoneID() -> CKRecordZone.ID {
    CKRecordZone.ID(
      zoneName: DeletionJournal.dataZoneName(for: profileId),
      ownerName: CKCurrentUserDefaultName)
  }

  private func entry(zone: String, recordName: String) -> DeletionJournalRow {
    DeletionJournalRow(
      zoneName: zone, recordName: recordName, recordType: "AccountRecord",
      queuedAt: 1_700_000_000)
  }

  @Test("data-zone replay maps sentinel entries onto the real profile-<id> zone")
  func dataZoneResolvesSentinelToRealZone() async throws {
    let zone = dataZoneID()
    let ids = SyncCoordinator.dataZoneDeletionReplayIDs(
      [
        entry(zone: DeletionJournal.profileDataSentinelZone, recordName: "AccountRecord|1"),
        entry(zone: DeletionJournal.profileDataSentinelZone, recordName: "AccountRecord|2"),
      ],
      dataZoneID: zone)
    #expect(ids.count == 2)
    #expect(ids.allSatisfy { $0.zoneID == zone })
    #expect(Set(ids.map(\.recordName)) == ["AccountRecord|1", "AccountRecord|2"])
    // Never the literal sentinel string as a zone.
    #expect(ids.allSatisfy { $0.zoneID.zoneName != DeletionJournal.profileDataSentinelZone })
  }

  @Test("data-zone replay skips a non-sentinel entry (never replays into the wrong zone)")
  func dataZoneSkipsNonSentinel() async throws {
    let ids = SyncCoordinator.dataZoneDeletionReplayIDs(
      [
        entry(zone: DeletionJournal.profileIndexZoneName, recordName: "ProfileRecord|9"),
        entry(zone: "profile-\(UUID().uuidString)", recordName: "AccountRecord|3"),
      ],
      dataZoneID: dataZoneID())
    #expect(ids.isEmpty)
  }

  @Test("index-zone replay maps index entries onto the profile-index zone, skipping sentinels")
  func indexZoneResolvesIndexEntries() async throws {
    let indexZone = CKRecordZone.ID(
      zoneName: DeletionJournal.profileIndexZoneName, ownerName: CKCurrentUserDefaultName)
    let ids = SyncCoordinator.indexZoneDeletionReplayIDs(
      [
        entry(zone: DeletionJournal.profileIndexZoneName, recordName: "ProfileRecord|7"),
        entry(zone: DeletionJournal.profileDataSentinelZone, recordName: "AccountRecord|4"),
      ],
      indexZoneID: indexZone)
    #expect(ids.map(\.recordName) == ["ProfileRecord|7"])
    #expect(ids.first?.zoneID == indexZone)
  }
}

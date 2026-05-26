import Foundation

/// A named, ordered grouping of accounts that share a sidebar bucket.
/// Members are discovered by querying accounts whose `groupId` equals
/// this group's `id` — there is intentionally no member-list field
/// here. A list field would create CloudKit update conflicts when
/// two devices add members concurrently; back-references on `Account`
/// are merged additively without coordination.
///
/// `bucket` is set on creation and immutable in v1; the UI enforces
/// same-bucket membership at the drop / move layer.
///
/// `isExpandedInSidebar` is a local-only preference and is not
/// persisted to CloudKit. There is no GRDB sidecar table for it yet,
/// so on app relaunch all groups start collapsed.
///
/// Adding or removing this type requires bumping `DataFormatVersion.current`.
struct AccountGroup {
  let id: UUID
  var name: String
  var bucket: AccountBucket
  var instrument: Instrument
  var position: Int
  var isExpandedInSidebar: Bool

  init(
    id: UUID = UUID(),
    name: String,
    bucket: AccountBucket,
    instrument: Instrument,
    position: Int = 0,
    isExpandedInSidebar: Bool = false
  ) {
    self.id = id
    self.name = name
    self.bucket = bucket
    self.instrument = instrument
    self.position = position
    self.isExpandedInSidebar = isExpandedInSidebar
  }
}

extension AccountGroup: Identifiable {}
extension AccountGroup: Sendable {}
extension AccountGroup: Hashable {}
extension AccountGroup: Codable {}

extension AccountGroup: Comparable {
  static func < (lhs: AccountGroup, rhs: AccountGroup) -> Bool {
    lhs.position < rhs.position
  }
}

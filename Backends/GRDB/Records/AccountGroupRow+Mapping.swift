import Foundation

extension AccountGroupRow {
  /// The CloudKit recordType on the wire. Frozen contract.
  static let recordType = "AccountGroupRecord"

  /// Canonical CloudKit `recordName` for a UUID-keyed group.
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  /// Builds a row from a domain `AccountGroup`. The `instrument` value
  /// is flattened to its id; the repository reconstructs the full
  /// `Instrument` on `toDomain`. `isExpandedInSidebar` is local-only
  /// preference state and is not carried in the row.
  init(domain: AccountGroup) {
    self.id = domain.id
    self.recordName = Self.recordName(for: domain.id)
    self.name = domain.name
    self.bucket = domain.bucket.rawValue
    self.instrumentId = domain.instrument.id
    self.position = domain.position
    self.encodedSystemFields = nil
  }

  /// Domain projection. `instruments` is the registry lookup
  /// table (`[String: Instrument]`); falls back to ambient fiat for
  /// unknown ids.
  ///
  /// An unknown `bucket` raw value falls back to `.current` as belt-
  /// and-braces; the `DataFormatVersion` gate is the real protection
  /// against a future bucket case reaching an older build.
  ///
  /// `isExpandedInSidebar` is always projected as `false`: the expand
  /// state is local-only and lives outside the GRDB row.
  ///
  /// Production callers MUST pass the loaded `instruments` registry;
  /// the empty-dict default exists only for unit-test convenience and
  /// causes every instrument to resolve via the `Instrument.fiat(code:)`
  /// fallback.
  func toDomain(instruments: [String: Instrument] = [:]) -> AccountGroup {
    let instrument = instruments[instrumentId] ?? Instrument.fiat(code: instrumentId)
    let resolvedBucket = AccountBucket(rawValue: bucket) ?? .current
    return AccountGroup(
      id: id,
      name: name,
      bucket: resolvedBucket,
      instrument: instrument,
      position: position,
      isExpandedInSidebar: false)
  }
}

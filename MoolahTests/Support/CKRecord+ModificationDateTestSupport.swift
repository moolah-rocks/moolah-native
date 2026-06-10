@preconcurrency import CloudKit
import Foundation

@testable import Moolah

// Test-only helper for stamping a server `modificationDate` onto an
// otherwise-local `CKRecord` (issue #1085). Production never stamps dates —
// CloudKit assigns `modificationDate` server-side — but the sync tests
// fabricate echoes via `row.toCKRecord(in:)`, which yields a fresh local
// record with `modificationDate == nil`. With the modification-date gate
// fully fail-open on `nil` dates, the loss reproductions can only exercise
// the gate when the fabricated echoes carry distinct, realistic dates.
//
// The stamp writes the system-fields archive's `RecordMtime` key as a
// `Date`, then re-applies the user fields (the encode/decode round-trip
// drops them). Empirically verified end-to-end (design doc §6): the value
// must be a `Date` (`Int64` / `Double` decode to `nil`), and it survives the
// production `encodedSystemFields` → `fromEncodedSystemFields` secure-coding
// round-trip the gate relies on.
extension CKRecord {
  func withModificationDate(_ date: Date) -> CKRecord {
    let coder = NSKeyedArchiver(requiringSecureCoding: true)
    encodeSystemFields(with: coder)
    // `RecordMtime` is CKRecord's internal archive key for the server
    // modification date. It is undocumented, so we assert the round-trip
    // produced a non-nil `modificationDate` below — if Apple ever renames
    // the key the helper fails loudly rather than silently fabricating a
    // dateless record that would make a loss test pass for the wrong reason.
    coder.encode(date as NSDate, forKey: "RecordMtime")
    coder.finishEncoding()

    let unarchiver: NSKeyedUnarchiver
    do {
      unarchiver = try NSKeyedUnarchiver(forReadingFrom: coder.encodedData)
    } catch {
      fatalError("withModificationDate: failed to build unarchiver: \(error)")
    }
    unarchiver.requiresSecureCoding = true
    guard let stamped = CKRecord(coder: unarchiver) else {
      fatalError("withModificationDate: failed to decode stamped CKRecord")
    }
    guard stamped.modificationDate != nil else {
      fatalError(
        "withModificationDate: RecordMtime did not survive the round-trip — "
          + "Apple may have renamed the archive key")
    }
    // `encodeSystemFields` drops user fields, so re-apply them.
    for key in allKeys() {
      stamped[key] = self[key]
    }
    return stamped
  }
}

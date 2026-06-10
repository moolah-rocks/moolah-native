@preconcurrency import CloudKit
import Foundation

@testable import Moolah

// Test-only conveniences for the issue-#1087 record-lookup tri-states, so
// existing round-trip / dispatch tests that just want the built `CKRecord`
// (the pre-#1087 `CKRecord?` shape) stay concise. Production callers must
// switch over all three cases — these helpers are deliberately test-only.
extension RecordLookupOutcome {
  /// The built record on `.found`, otherwise `nil` (`.absent` / `.failed`).
  var foundRecord: CKRecord? {
    if case .found(let record) = self { return record }
    return nil
  }
}

extension BatchLookupOutcome {
  /// The hit map on `.succeeded`, or an empty map on `.failed`. Tests that
  /// use this expect a `.succeeded` outcome and assert on the hits; the
  /// `.failed` case is exercised directly via `guard case .failed`.
  var succeededHits: [UUID: CKRecord] {
    if case .succeeded(let hits) = self { return hits }
    return [:]
  }
}

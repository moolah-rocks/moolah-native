import Foundation

@testable import Moolah

/// `@unchecked Sendable` test helper: `lock` guards every access to
/// `recordedIds`, and no lock is held across suspension.
final class TaxOwnerChangeRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recordedIds: [UUID] = []

  var ids: [UUID] {
    lock.withLock { recordedIds }
  }

  func record(_ recordType: String, _ id: UUID) {
    guard recordType == TaxOwnerRow.recordType else { return }
    lock.withLock {
      recordedIds.append(id)
    }
  }
}

final class ReferenceChangeRecorder: @unchecked Sendable {
  private let expectedRecordType: String
  private let lock = NSLock()
  private var recordedIds: [UUID] = []

  init(expectedRecordType: String) {
    self.expectedRecordType = expectedRecordType
  }

  var ids: [UUID] {
    lock.withLock { recordedIds }
  }

  func record(_ recordType: String, _ id: UUID) {
    guard recordType == expectedRecordType else { return }
    lock.withLock {
      recordedIds.append(id)
    }
  }
}

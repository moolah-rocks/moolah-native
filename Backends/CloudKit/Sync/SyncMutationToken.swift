@preconcurrency import CloudKit

enum SyncMutationToken {
  static let cloudField = "mutationToken"

  static func attach(_ token: String?, to record: CKRecord) -> CKRecord {
    record[cloudField] = token as CKRecordValue?
    return record
  }
}

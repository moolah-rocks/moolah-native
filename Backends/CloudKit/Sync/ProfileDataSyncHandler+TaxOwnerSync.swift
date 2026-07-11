// Backends/CloudKit/Sync/ProfileDataSyncHandler+TaxOwnerSync.swift

@preconcurrency import CloudKit
import Foundation
import GRDB

extension ProfileDataSyncHandler {
  nonisolated func applyBatchSaveTaxOwner(
    ckRecords: [CKRecord], systemFields: [String: Data], in database: Database
  ) throws {
    let context = GRDBBatchSaveContext(
      ckRecords: ckRecords,
      systemFields: systemFields,
      site: "applyGRDBBatchSave[TaxOwner]")
    let rows = mapRows(
      context: context,
      fieldValues: TaxOwnerRow.fieldValues(from:),
      idKey: { $0.id.uuidString },
      stamp: stampSystemFields)
    try writeRemote(site: context.site) {
      try grdbRepositories.taxOwners.applyRemoteChangesSync(
        saved: rows, deleted: [], in: database)
    }
  }

  nonisolated func taxOwnerDeleter(
    for recordType: String
  ) -> ((ProfileDataSyncHandler, [UUID], Database) throws -> Void)? {
    guard recordType == TaxOwnerRow.recordType else { return nil }
    return { handler, ids, database in
      try handler.writeRemote(site: "applyGRDBBatchDeletion[TaxOwner]") {
        try handler.grdbRepositories.taxOwners.applyRemoteChangesSync(
          saved: [], deleted: ids, in: database)
      }
    }
  }

  nonisolated func applyBatchDeleteTaxOwner(
    ids: [UUID], in database: Database
  ) throws -> GRDBTaxOwnerRepository.RemovedOwnerReferences {
    var removedReferences = GRDBTaxOwnerRepository.RemovedOwnerReferences(
      accountIds: [], categoryIds: [])
    try writeRemote(site: "applyGRDBBatchDeletion[TaxOwner]") {
      removedReferences = try grdbRepositories.taxOwners.applyRemoteChangesSync(
        saved: [], deleted: ids, in: database)
    }
    return removedReferences
  }
}

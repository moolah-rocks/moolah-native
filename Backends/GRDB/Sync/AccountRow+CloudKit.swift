// Backends/GRDB/Sync/AccountRow+CloudKit.swift

import CloudKit
import Foundation
import OSLog

private let accountRowSyncLogger = Logger(
  subsystem: "com.moolah.app", category: "AccountRow+CloudKit")

// MARK: - AccountRow + CloudKitRecordConvertible
//
// Replaces `Backends/CloudKit/Sync/AccountRecord+CloudKit.swift`. The
// CloudKit wire `recordType` ("AccountRecord") is a frozen contract —
// existing iCloud zones reference this exact string — so it stays
// unchanged regardless of the local Swift type's name.

extension AccountRow: CloudKitRecordConvertible {
  func toCKRecord(in zoneID: CKRecordZone.ID) -> CKRecord {
    let recordID = CKRecord.ID(
      recordType: Self.recordType, uuid: id, zoneID: zoneID)
    let record = CKRecord(recordType: Self.recordType, recordID: recordID)
    AccountRecordCloudKitFields(
      chainId: chainId.map(Int64.init),
      exchangeProvider: exchangeProvider,
      groupId: groupId?.uuidString,
      instrumentId: instrumentId,
      isHidden: isHidden ? 1 : 0,
      name: name,
      position: Int64(position),
      type: type,
      valuationMode: valuationMode,
      walletAddress: walletAddress
    ).write(to: record)
    return record
  }

  static func fieldValues(from ckRecord: CKRecord) -> AccountRow? {
    guard let id = ckRecord.recordID.uuid else { return nil }
    let fields = AccountRecordCloudKitFields(from: ckRecord)
    return AccountRow(
      id: id,
      recordName: ckRecord.recordID.recordName,
      name: fields.name ?? "",
      type: Self.safeAccountTypeRaw(fields.type ?? "bank"),
      instrumentId: fields.instrumentId ?? "AUD",
      position: Int(fields.position ?? 0),
      isHidden: (fields.isHidden ?? 0) != 0,
      // Stamped by applyGRDBBatchSave after upsert; never read from the
      // CKRecord itself.
      encodedSystemFields: nil,
      valuationMode: fields.valuationMode ?? "recordedValue",
      walletAddress: fields.walletAddress,
      chainId: fields.chainId.map(Int.init),
      exchangeProvider: fields.exchangeProvider,
      groupId: fields.groupId.flatMap(UUID.init(uuidString:))
    )
  }

  /// Maps an unrecognised `type` raw value to `"asset"` so that an older
  /// build receiving an account row from a newer device (e.g. with
  /// `type = "crypto"` before this build added the case, or any future
  /// type after) doesn't fail the GRDB CHECK constraint and block sync
  /// for the entire zone. Logs a single warning per unknown value so the
  /// drift is visible in Console.
  static func safeAccountTypeRaw(_ raw: String) -> String {
    let known: Set<String> = [
      "bank", "cc", "asset", "investment", "crypto", "exchange",
    ]
    if known.contains(raw) { return raw }
    accountRowSyncLogger.warning(
      """
      Unknown account row type "\(raw, privacy: .public)" from CloudKit — \
      falling back to "asset" so sync isn't blocked. Update the app to a \
      build that recognises this type.
      """)
    return "asset"
  }
}

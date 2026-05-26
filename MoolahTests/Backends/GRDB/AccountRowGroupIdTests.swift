// MoolahTests/Backends/GRDB/AccountRowGroupIdTests.swift
import CloudKit
import Foundation
import Testing

@testable import Moolah

@Suite("AccountRow.groupId")
struct AccountRowGroupIdTests {
  @Test("init(domain:) writes groupId from the domain account")
  func initFromDomain() {
    let groupId = UUID()
    let account = Account(
      name: "Coinstash", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash, groupId: groupId)
    let row = AccountRow(domain: account)
    #expect(row.groupId == groupId)
  }

  @Test("init(domain:) passes nil groupId through as nil")
  func initFromDomainNilGroupId() {
    let account = Account(
      name: "Chequing", type: .bank, instrument: .AUD)
    let row = AccountRow(domain: account)
    #expect(row.groupId == nil)
  }

  @Test("toDomain reads groupId back through the GRDB row")
  func toDomainReadsGroupId() throws {
    let groupId = UUID()
    let row = AccountRow(
      id: UUID(), recordName: "AccountRecord|x", name: "Coinstash",
      type: "exchange", instrumentId: "AUD", position: 0,
      isHidden: false, encodedSystemFields: nil,
      valuationMode: "calculatedFromTrades",
      walletAddress: nil, chainId: nil,
      exchangeProvider: "coinstash",
      groupId: groupId)
    let account = try row.toDomain()
    #expect(account.groupId == groupId)
  }

  @Test("toDomain passes nil groupId through")
  func toDomainNilGroupId() throws {
    let row = AccountRow(
      id: UUID(), recordName: "AccountRecord|x", name: "Chequing",
      type: "bank", instrumentId: "AUD", position: 0,
      isHidden: false, encodedSystemFields: nil,
      valuationMode: "recordedValue",
      walletAddress: nil, chainId: nil,
      exchangeProvider: nil,
      groupId: nil)
    let account = try row.toDomain()
    #expect(account.groupId == nil)
  }

  @Test("toCKRecord writes groupId as uuidString")
  func toCKRecordWritesGroupId() throws {
    let groupId = UUID()
    let row = AccountRow(
      id: UUID(), recordName: "AccountRecord|x", name: "Coinstash",
      type: "exchange", instrumentId: "AUD", position: 0,
      isHidden: false, encodedSystemFields: nil,
      valuationMode: "calculatedFromTrades",
      walletAddress: nil, chainId: nil,
      exchangeProvider: "coinstash",
      groupId: groupId)
    let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
    let ckRecord = row.toCKRecord(in: zoneID)
    let written = try #require(ckRecord["groupId"] as? String)
    #expect(written == groupId.uuidString)
  }

  @Test("toCKRecord omits groupId when nil")
  func toCKRecordOmitsNilGroupId() {
    let row = AccountRow(
      id: UUID(), recordName: "AccountRecord|x", name: "Chequing",
      type: "bank", instrumentId: "AUD", position: 0,
      isHidden: false, encodedSystemFields: nil,
      valuationMode: "recordedValue",
      walletAddress: nil, chainId: nil,
      exchangeProvider: nil,
      groupId: nil)
    let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
    let ckRecord = row.toCKRecord(in: zoneID)
    #expect(ckRecord["groupId"] == nil)
  }

  @Test("fieldValues(from:) reads groupId string into UUID?")
  func fieldValuesReadsGroupIdFromCKRecord() throws {
    let accountId = UUID()
    let groupId = UUID()
    let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
    let recordID = CKRecord.ID(
      recordType: "AccountRecord", uuid: accountId, zoneID: zoneID)
    let ckRecord = CKRecord(recordType: "AccountRecord", recordID: recordID)
    ckRecord["name"] = "Coinstash" as CKRecordValue
    ckRecord["type"] = "exchange" as CKRecordValue
    ckRecord["instrumentId"] = "AUD" as CKRecordValue
    ckRecord["position"] = Int64(0) as CKRecordValue
    ckRecord["isHidden"] = Int64(0) as CKRecordValue
    ckRecord["valuationMode"] = "calculatedFromTrades" as CKRecordValue
    ckRecord["exchangeProvider"] = "coinstash" as CKRecordValue
    ckRecord["groupId"] = groupId.uuidString as CKRecordValue
    let row = try #require(AccountRow.fieldValues(from: ckRecord))
    #expect(row.groupId == groupId)
  }

  @Test("fieldValues(from:) reads nil when groupId is absent")
  func fieldValuesReadsNilGroupId() throws {
    let accountId = UUID()
    let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
    let recordID = CKRecord.ID(
      recordType: "AccountRecord", uuid: accountId, zoneID: zoneID)
    let ckRecord = CKRecord(recordType: "AccountRecord", recordID: recordID)
    ckRecord["name"] = "Chequing" as CKRecordValue
    ckRecord["type"] = "bank" as CKRecordValue
    ckRecord["instrumentId"] = "AUD" as CKRecordValue
    ckRecord["position"] = Int64(0) as CKRecordValue
    ckRecord["isHidden"] = Int64(0) as CKRecordValue
    ckRecord["valuationMode"] = "recordedValue" as CKRecordValue
    let row = try #require(AccountRow.fieldValues(from: ckRecord))
    #expect(row.groupId == nil)
  }

  @Test("fieldValues(from:) maps malformed groupId string to nil")
  func fieldValuesMalformedGroupId() throws {
    let accountId = UUID()
    let zoneID = CKRecordZone.ID(zoneName: "z", ownerName: CKCurrentUserDefaultName)
    let recordID = CKRecord.ID(
      recordType: "AccountRecord", uuid: accountId, zoneID: zoneID)
    let ckRecord = CKRecord(recordType: "AccountRecord", recordID: recordID)
    ckRecord["name"] = "Broken" as CKRecordValue
    ckRecord["type"] = "bank" as CKRecordValue
    ckRecord["instrumentId"] = "AUD" as CKRecordValue
    ckRecord["position"] = Int64(0) as CKRecordValue
    ckRecord["isHidden"] = Int64(0) as CKRecordValue
    ckRecord["valuationMode"] = "recordedValue" as CKRecordValue
    ckRecord["groupId"] = "not-a-uuid" as CKRecordValue
    let row = try #require(AccountRow.fieldValues(from: ckRecord))
    #expect(row.groupId == nil)
  }
}

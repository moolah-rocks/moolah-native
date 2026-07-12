import CloudKit
import Testing

@testable import Moolah

struct ExchangeAccountCloudKitTests {
  @Test
  func exchangeTypeSurvivesRoundTrip() {
    #expect(AccountRow.safeAccountTypeRaw("exchange") == "exchange")
  }

  @Test
  func unknownTypeStillFallsBackToAsset() {
    #expect(AccountRow.safeAccountTypeRaw("nonsense") == "asset")
  }

  @Test
  func exchangeProviderSurvivesCloudKitRoundTrip() throws {
    let row = AccountRow(
      id: UUID(),
      recordName: "rec",
      name: "Coinstash",
      type: "exchange",
      instrumentId: "AUD",
      position: 0,
      isHidden: false,
      encodedSystemFields: nil,
      walletAddress: nil,
      chainId: nil,
      exchangeProvider: "coinstash")
    let zoneID = CKRecordZone.ID(
      zoneName: "test", ownerName: CKCurrentUserDefaultName)
    let restored = AccountRow.fieldValues(from: row.toCKRecord(in: zoneID))
    #expect(restored?.exchangeProvider == "coinstash")
  }

  @Test
  func unknownFutureProviderPassesThroughRaw() throws {
    let row = AccountRow(
      id: UUID(),
      recordName: "r2",
      name: "X",
      type: "exchange",
      instrumentId: "AUD",
      position: 0,
      isHidden: false,
      encodedSystemFields: nil,
      walletAddress: nil,
      chainId: nil,
      exchangeProvider: "future-exchange")
    let zoneID = CKRecordZone.ID(
      zoneName: "test", ownerName: CKCurrentUserDefaultName)
    let restored = AccountRow.fieldValues(from: row.toCKRecord(in: zoneID))
    #expect(restored?.exchangeProvider == "future-exchange")
  }

  @Test
  func toCKRecordEncodesExchangeProvider() throws {
    let row = AccountRow(
      id: UUID(),
      recordName: "r3",
      name: "C",
      type: "exchange",
      instrumentId: "AUD",
      position: 0,
      isHidden: false,
      encodedSystemFields: nil,
      walletAddress: nil,
      chainId: nil,
      exchangeProvider: "coinstash")
    let zoneID = CKRecordZone.ID(
      zoneName: "test", ownerName: CKCurrentUserDefaultName)
    let record = row.toCKRecord(in: zoneID)
    #expect(record["exchangeProvider"] as? String == "coinstash")
  }
}

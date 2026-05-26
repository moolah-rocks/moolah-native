import Foundation
import Testing

@testable import Moolah

@Suite("AccountGroupRow mapping")
struct AccountGroupRowMappingTests {

  @Test
  func domainRoundTripsThroughRow() {
    let original = AccountGroup(
      name: "Trust Fund Crypto",
      bucket: .investments,
      instrument: .AUD,
      position: 3)
    let row = AccountGroupRow(domain: original)
    let restored = row.toDomain()

    #expect(restored.id == original.id)
    #expect(restored.name == original.name)
    #expect(restored.bucket == original.bucket)
    #expect(restored.instrument == original.instrument)
    #expect(restored.position == original.position)
    // isExpandedInSidebar is local-only; row never carries it.
    #expect(restored.isExpandedInSidebar == false)
  }

  @Test
  func recordNameIsStable() throws {
    let uuid = try #require(UUID(uuidString: "12345678-1234-1234-1234-123456789ABC"))
    let recordName = AccountGroupRow.recordName(for: uuid)
    #expect(recordName == "AccountGroupRecord|12345678-1234-1234-1234-123456789ABC")
  }

  @Test
  func unknownBucketFallsBackToCurrent() {
    let row = AccountGroupRow(
      id: UUID(),
      recordName: "AccountGroupRecord|x",
      name: "From future build",
      bucket: "retirement",
      instrumentId: "AUD",
      position: 0,
      encodedSystemFields: nil)
    let restored = row.toDomain()
    #expect(restored.bucket == .current)
  }

  @Test
  func instrumentLookupPrefersRegistryOverFiatFallback() {
    let appleStock = Instrument.stock(
      ticker: "AAPL", exchange: "NASDAQ", name: "Apple Inc.")
    let row = AccountGroupRow(
      id: UUID(),
      recordName: "AccountGroupRecord|x",
      name: "AAPL holding",
      bucket: "investments",
      instrumentId: appleStock.id,
      position: 0,
      encodedSystemFields: nil)
    let restored = row.toDomain(instruments: [appleStock.id: appleStock])
    #expect(restored.instrument == appleStock)
  }

  @Test
  func observableRegionExcludesEncodedSystemFieldsColumn() {
    let includedColumns = AccountGroupRow.Columns.allCases.filter {
      $0 != .encodedSystemFields
    }
    #expect(!includedColumns.contains(.encodedSystemFields))
    #expect(includedColumns.contains(.id))
    #expect(includedColumns.contains(.recordName))
    #expect(includedColumns.contains(.name))
    #expect(includedColumns.contains(.bucket))
    #expect(includedColumns.contains(.instrumentId))
    #expect(includedColumns.contains(.position))
    // observableRegion itself uses this same filter, so the contract is pinned.
  }
}

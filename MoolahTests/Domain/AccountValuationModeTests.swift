import Foundation
import Testing

@testable import Moolah

@Suite("Account.valuationMode")
struct AccountValuationModeTests {
  @Test("default is calculatedFromTrades")
  func defaultIsCalculatedFromTrades() {
    let account = Account(name: "Brokerage", type: .investment, instrument: .AUD)
    #expect(account.valuationMode == .calculatedFromTrades)
  }

  @Test("explicit init sets the field")
  func explicitInit() {
    let account = Account(
      name: "Brokerage", type: .investment, instrument: .AUD,
      valuationMode: .calculatedFromTrades)
    #expect(account.valuationMode == .calculatedFromTrades)
  }

  @Test("Codable round-trips both cases")
  func codableRoundTrip() throws {
    for mode in ValuationMode.allCases {
      let original = Account(
        name: "X", type: .investment, instrument: .AUD, valuationMode: mode)
      let data = try JSONEncoder().encode(original)
      let decoded = try JSONDecoder().decode(Account.self, from: data)
      #expect(decoded == original)
    }
  }

  @Test("Codable decodes missing key as calculatedFromTrades")
  func codableMissingKey() throws {
    let json = Data(
      """
      {
        "id": "00000000-0000-0000-0000-000000000001",
        "name": "Old",
        "type": "investment",
        "instrument": { "id": "AUD", "kind": "fiatCurrency",
                        "name": "AUD", "decimals": 2 },
        "position": 0,
        "hidden": false
      }
      """.utf8)
    let decoded = try JSONDecoder().decode(Account.self, from: json)
    #expect(decoded.valuationMode == .calculatedFromTrades)
  }

  @Test("Equality includes valuationMode")
  func equalityIncludesMode() {
    let original = Account(
      name: "A", type: .investment, instrument: .AUD,
      valuationMode: .recordedValue)
    var modified = original
    modified.valuationMode = .calculatedFromTrades
    #expect(original.id == modified.id)
    #expect(original != modified)
  }
}

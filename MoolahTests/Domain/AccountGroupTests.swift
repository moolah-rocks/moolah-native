import Foundation
import Testing

@testable import Moolah

@Suite("AccountGroup")
struct AccountGroupTests {
  @Test
  func memberwiseInitDefaultsExpandedFalse() {
    let group = AccountGroup(
      name: "Trust Fund Crypto",
      bucket: .investments,
      instrument: .AUD
    )
    #expect(group.isExpandedInSidebar == false)
  }

  @Test
  func roundTripsThroughCodable() throws {
    let original = AccountGroup(
      id: UUID(),
      name: "Personal Crypto",
      bucket: .investments,
      instrument: .AUD,
      position: 3,
      isExpandedInSidebar: true
    )
    let encoded = try JSONEncoder().encode(original)
    let restored = try JSONDecoder().decode(AccountGroup.self, from: encoded)

    #expect(restored == original)
  }

  @Test
  func sameIdDifferentFieldsAreDistinctInSet() {
    let sharedId = UUID()
    let first = AccountGroup(id: sharedId, name: "A", bucket: .investments, instrument: .AUD)
    let second = AccountGroup(id: sharedId, name: "B", bucket: .current, instrument: .USD)
    var set: Set<AccountGroup> = [first]
    set.insert(second)
    // Different content, same id → set still has both because Hashable uses
    // the synthesised field-hash. The point of this test is to lock in
    // value-semantics (no id-only equality) — if you change the Hashable
    // impl to id-only, this test fails and forces a design conversation.
    #expect(set.count == 2)
  }

  @Test
  func comparableSortsByPosition() {
    let groupA = AccountGroup(name: "A", bucket: .investments, instrument: .AUD, position: 2)
    let groupB = AccountGroup(name: "B", bucket: .investments, instrument: .AUD, position: 0)
    let groupC = AccountGroup(name: "C", bucket: .investments, instrument: .AUD, position: 1)
    let sorted = [groupA, groupB, groupC].sorted()
    #expect(sorted.map(\.name) == ["B", "C", "A"])
  }
}

import Testing

@testable import Moolah

@Suite("TransactionDetailSyncSection.label(for:)")
struct TransactionDetailSyncSectionTests {
  @Test
  func singleSourceReadsSyncedFromThatSource() {
    #expect(TransactionDetailSyncSection.label(for: [.wallet]) == "Synced from Wallet")
    #expect(TransactionDetailSyncSection.label(for: [.coinstash]) == "Synced from Coinstash")
  }

  @Test
  func twoSourcesListBothNamesInDeclarationOrder() {
    // Uses a localized list conjunction, so assert the prefix and the source
    // ordering (Wallet before Coinstash, per BackgroundSyncSource's declared
    // order) rather than the exact conjunction word, which is locale-dependent.
    let text = TransactionDetailSyncSection.label(for: [.wallet, .coinstash])
    #expect(text.hasPrefix("Synced from "))
    guard let walletRange = text.range(of: "Wallet"),
      let coinstashRange = text.range(of: "Coinstash")
    else {
      Issue.record("Expected both source names in \(text)")
      return
    }
    #expect(walletRange.lowerBound < coinstashRange.lowerBound)
  }
}

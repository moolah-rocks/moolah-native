import Foundation
import Testing

@testable import Moolah

@Suite("AccountMultiSelectPicker selection summary")
struct AccountMultiSelectPickerSummaryTests {
  private func account(_ name: String, _ id: UUID) -> Account {
    Account(
      id: id, name: name, type: .bank, instrument: .AUD,
      positions: [Position(instrument: .AUD, quantity: 0)])
  }

  @Test("Empty selection reads All accounts")
  func testEmptyIsAllAccounts() {
    let checking = account("Checking", UUID())
    #expect(
      AccountMultiSelectPicker.selectionSummary(for: [], available: [checking])
        == "All accounts")
  }

  @Test("Single selection reads the account name")
  func testSingleIsName() {
    let id = UUID()
    let checking = account("Checking", id)
    let savings = account("Savings", UUID())
    #expect(
      AccountMultiSelectPicker.selectionSummary(for: [id], available: [checking, savings])
        == "Checking")
  }

  @Test("Multiple selection reads N accounts")
  func testManyIsCount() {
    let idA = UUID()
    let idB = UUID()
    let checking = account("Checking", idA)
    let savings = account("Savings", idB)
    #expect(
      AccountMultiSelectPicker.selectionSummary(for: [idA, idB], available: [checking, savings])
        == "2 accounts")
  }

  @Test("Selection counts only ids present in the available list")
  func testCountsOnlyPresent() {
    let idA = UUID()
    let checking = account("Checking", idA)
    #expect(
      AccountMultiSelectPicker.selectionSummary(
        for: [idA, UUID()], available: [checking]) == "Checking")
  }
}

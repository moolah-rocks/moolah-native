import Foundation
import Testing

@testable import Moolah

@Suite("HandoffTitleProvider")
@MainActor
struct HandoffTitleProviderTests {

  struct FakeAccountLookup: HandoffAccountLookup {
    var nameByID: [UUID: String] = [:]

    func displayName(for id: UUID) -> String? { nameByID[id] }
  }

  struct FakeEarmarkLookup: HandoffEarmarkLookup {
    var nameByID: [UUID: String] = [:]

    func displayName(for id: UUID) -> String? { nameByID[id] }
  }

  @Test("account destination returns the account display name")
  func accountTitle() throws {
    let id = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    let accounts = FakeAccountLookup(nameByID: [id: "Chase Checking"])
    let title = HandoffTitleProvider.title(
      for: .account(id),
      accounts: accounts,
      earmarks: FakeEarmarkLookup())
    #expect(title == "Chase Checking")
  }

  @Test("account destination falls back to 'Account' when name is unknown")
  func accountTitleFallback() throws {
    let id = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
    let title = HandoffTitleProvider.title(
      for: .account(id),
      accounts: FakeAccountLookup(),
      earmarks: FakeEarmarkLookup())
    #expect(title == "Account")
  }

  @Test("earmark destination returns the earmark display name")
  func earmarkTitle() throws {
    let id = try #require(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
    let earmarks = FakeEarmarkLookup(nameByID: [id: "Holiday"])
    let title = HandoffTitleProvider.title(
      for: .earmark(id),
      accounts: FakeAccountLookup(),
      earmarks: earmarks)
    #expect(title == "Holiday")
  }

  @Test("earmark destination falls back to 'Earmark' when name is unknown")
  func earmarkTitleFallback() throws {
    let id = try #require(UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
    let title = HandoffTitleProvider.title(
      for: .earmark(id),
      accounts: FakeAccountLookup(),
      earmarks: FakeEarmarkLookup())
    #expect(title == "Earmark")
  }

  @Test("transaction destination returns 'Transaction'")
  func transactionTitle() throws {
    let id = try #require(UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
    let title = HandoffTitleProvider.title(
      for: .transaction(id),
      accounts: FakeAccountLookup(),
      earmarks: FakeEarmarkLookup())
    #expect(title == "Transaction")
  }

  @Test("static destinations return their static titles")
  func staticTitles() {
    let accounts = FakeAccountLookup()
    let earmarks = FakeEarmarkLookup()
    #expect(
      HandoffTitleProvider.title(for: .accounts, accounts: accounts, earmarks: earmarks)
        == "Accounts")
    #expect(
      HandoffTitleProvider.title(for: .earmarks, accounts: accounts, earmarks: earmarks)
        == "Earmarks")
    #expect(
      HandoffTitleProvider.title(
        for: .reports(from: nil, to: nil), accounts: accounts, earmarks: earmarks) == "Reports")
    #expect(
      HandoffTitleProvider.title(
        for: .analysis(history: nil, forecast: nil), accounts: accounts, earmarks: earmarks)
        == "Analysis")
    #expect(
      HandoffTitleProvider.title(for: .categories, accounts: accounts, earmarks: earmarks)
        == "Categories")
    #expect(
      HandoffTitleProvider.title(for: .upcoming, accounts: accounts, earmarks: earmarks)
        == "Upcoming")
  }
}

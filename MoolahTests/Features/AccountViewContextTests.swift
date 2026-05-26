import Foundation
import Testing

@testable import Moolah

@Suite("AccountViewContext")
struct AccountViewContextTests {

  @Test("single-account context exposes one id and account kind")
  func singleAccountContext() {
    let id = UUID()
    let context = AccountViewContext(
      kind: .account,
      displayName: "Checking",
      displayInstrument: .defaultTestInstrument,
      bucket: .current,
      accountIds: [id],
      syncStatus: .allSynced)
    #expect(context.kind == .account)
    #expect(context.accountIds == [id])
    #expect(context.supportsPerAccountSyncControls == true)
  }

  @Test("group context exposes N ids and group kind")
  func groupContextNIds() {
    let ids = [UUID(), UUID(), UUID()]
    let context = AccountViewContext(
      kind: .group,
      displayName: "Trust Fund Crypto",
      displayInstrument: .defaultTestInstrument,
      bucket: .investments,
      accountIds: ids,
      syncStatus: .allSynced)
    #expect(context.kind == .group)
    #expect(context.accountIds == ids)
    #expect(context.supportsPerAccountSyncControls == false)
  }

  @Test("supportsPerAccountSyncControls is false for empty single-account context")
  func supportsControlsRequiresNonEmpty() {
    let context = AccountViewContext(
      kind: .account,
      displayName: "Empty",
      displayInstrument: .defaultTestInstrument,
      bucket: .current,
      accountIds: [],
      syncStatus: .allSynced)
    #expect(context.supportsPerAccountSyncControls == false)
  }

  @Test("supportsPerAccountSyncControls is false for any group context")
  func supportsControlsFalseForGroup() {
    let context = AccountViewContext(
      kind: .group,
      displayName: "Solo Group",
      displayInstrument: .defaultTestInstrument,
      bucket: .investments,
      accountIds: [UUID()],
      syncStatus: .allSynced)
    #expect(context.supportsPerAccountSyncControls == false)
  }
}

@Suite("AccountSyncStatus")
struct AccountSyncStatusTests {

  @Test("synced status has no error and is not in progress")
  func syncedStatus() {
    let status = AccountSyncStatus(accountId: UUID(), isInProgress: false, hasError: false)
    #expect(status.isInProgress == false)
    #expect(status.hasError == false)
  }

  @Test("in-progress status flags isInProgress")
  func inProgressStatus() {
    let status = AccountSyncStatus(accountId: UUID(), isInProgress: true, hasError: false)
    #expect(status.isInProgress == true)
  }

  @Test("failed status flags hasError")
  func failedStatus() {
    let status = AccountSyncStatus(accountId: UUID(), isInProgress: false, hasError: true)
    #expect(status.hasError == true)
  }
}

@Suite("AggregatedSyncStatus")
struct AggregatedSyncStatusTests {

  @Test("empty input is allSynced")
  func emptyIsAllSynced() {
    #expect(AggregatedSyncStatus.aggregate([]) == .allSynced)
  }

  @Test("all synced collapses to allSynced")
  func allSynced() {
    let statuses = [
      AccountSyncStatus(accountId: UUID(), isInProgress: false, hasError: false),
      AccountSyncStatus(accountId: UUID(), isInProgress: false, hasError: false),
    ]
    #expect(AggregatedSyncStatus.aggregate(statuses) == .allSynced)
  }

  @Test("any failed produces failed with member ids")
  func oneFailed() {
    let failedId = UUID()
    let statuses = [
      AccountSyncStatus(accountId: UUID(), isInProgress: false, hasError: false),
      AccountSyncStatus(accountId: failedId, isInProgress: false, hasError: true),
      AccountSyncStatus(accountId: UUID(), isInProgress: false, hasError: false),
    ]
    #expect(AggregatedSyncStatus.aggregate(statuses) == .failed(memberIds: [failedId]))
  }

  @Test("multiple failed listed in input order")
  func multipleFailed() {
    let firstFailed = UUID()
    let secondFailed = UUID()
    let statuses = [
      AccountSyncStatus(accountId: firstFailed, isInProgress: false, hasError: true),
      AccountSyncStatus(accountId: UUID(), isInProgress: false, hasError: false),
      AccountSyncStatus(accountId: secondFailed, isInProgress: false, hasError: true),
    ]
    #expect(
      AggregatedSyncStatus.aggregate(statuses)
        == .failed(memberIds: [firstFailed, secondFailed]))
  }

  @Test("all in progress reports syncing with full total")
  func allInProgress() {
    let statuses = [
      AccountSyncStatus(accountId: UUID(), isInProgress: true, hasError: false),
      AccountSyncStatus(accountId: UUID(), isInProgress: true, hasError: false),
      AccountSyncStatus(accountId: UUID(), isInProgress: true, hasError: false),
    ]
    #expect(AggregatedSyncStatus.aggregate(statuses) == .syncing(done: 0, total: 3))
  }

  @Test("mix of in-progress and synced reports done/total")
  func mixedInProgress() {
    let statuses = [
      AccountSyncStatus(accountId: UUID(), isInProgress: false, hasError: false),
      AccountSyncStatus(accountId: UUID(), isInProgress: true, hasError: false),
      AccountSyncStatus(accountId: UUID(), isInProgress: false, hasError: false),
    ]
    #expect(AggregatedSyncStatus.aggregate(statuses) == .syncing(done: 2, total: 3))
  }

  @Test("failed takes precedence over in-progress")
  func failedOverInProgress() {
    let failedId = UUID()
    let statuses = [
      AccountSyncStatus(accountId: UUID(), isInProgress: true, hasError: false),
      AccountSyncStatus(accountId: failedId, isInProgress: false, hasError: true),
    ]
    #expect(AggregatedSyncStatus.aggregate(statuses) == .failed(memberIds: [failedId]))
  }

  @Test("single-element synced collapses to allSynced — same path serves single accounts")
  func singleSyncedCollapses() {
    let statuses = [
      AccountSyncStatus(accountId: UUID(), isInProgress: false, hasError: false)
    ]
    #expect(AggregatedSyncStatus.aggregate(statuses) == .allSynced)
  }

  @Test("single-element in-progress collapses to syncing(0,1)")
  func singleInProgressCollapses() {
    let statuses = [
      AccountSyncStatus(accountId: UUID(), isInProgress: true, hasError: false)
    ]
    #expect(AggregatedSyncStatus.aggregate(statuses) == .syncing(done: 0, total: 1))
  }

  @Test("single-element failed collapses to failed(memberIds: [id])")
  func singleFailedCollapses() {
    let failedId = UUID()
    let statuses = [
      AccountSyncStatus(accountId: failedId, isInProgress: false, hasError: true)
    ]
    #expect(AggregatedSyncStatus.aggregate(statuses) == .failed(memberIds: [failedId]))
  }
}

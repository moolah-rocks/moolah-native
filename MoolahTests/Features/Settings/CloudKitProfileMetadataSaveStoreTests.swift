import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("CloudKit profile metadata save store")
struct CloudKitProfileMetadataSaveStoreTests {
  @Test("scheduled metadata saves run in submission order")
  func scheduledMetadataSavesRunInSubmissionOrder() async {
    let recorder = MetadataUpdateRecorder()
    let store = CloudKitProfileMetadataSaveStore(
      updateProfile: { update in
        var profile = Profile(label: "Original", currencyCode: "AUD", financialYearStartMonth: 7)
        update(&profile)
        await recorder.recordSaved(profile)
        return profile
      },
      onError: { _ in })

    store.scheduleSave(label: "First", currencyCode: "AUD", financialYearStartMonth: 7)
    store.scheduleSave(label: "Second", currencyCode: "USD", financialYearStartMonth: 1)

    await store.waitForPendingSaves()

    #expect(await recorder.savedLabels == ["First", "Second"])
    #expect(await recorder.savedCurrencyCodes == ["AUD", "USD"])
  }

  @Test("cancelling the store cancels owned metadata save tasks")
  func cancellingTheStoreCancelsOwnedMetadataSaveTasks() async {
    let gate = Gate()
    let recorder = MetadataUpdateRecorder()
    let store = CloudKitProfileMetadataSaveStore(
      updateProfile: { update in
        await recorder.recordAttempt()
        await gate.wait()
        do {
          try Task.checkCancellation()
        } catch {
          await recorder.recordCancellation()
          throw error
        }
        var profile = Profile(label: "Original", currencyCode: "AUD", financialYearStartMonth: 7)
        update(&profile)
        await recorder.recordSaved(profile)
        return profile
      },
      onError: { error in
        Issue.record("Cancellation should not be presented as a save error: \(error)")
      })

    store.scheduleSave(label: "Cancelled", currencyCode: "USD", financialYearStartMonth: 1)
    while await recorder.attemptCount == 0 { await Task.yield() }

    store.cancelPendingSaves()
    await gate.open()
    await store.waitForPendingSaves()

    #expect(await recorder.cancellationCount == 1)
    #expect(await recorder.savedLabels.isEmpty)
  }

  private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
      if isOpen { return }
      await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
      isOpen = true
      let waiters = waiters
      self.waiters.removeAll()
      for waiter in waiters { waiter.resume() }
    }
  }

  private actor MetadataUpdateRecorder {
    private(set) var attemptCount = 0
    private(set) var cancellationCount = 0
    private(set) var savedLabels: [String] = []
    private(set) var savedCurrencyCodes: [String] = []

    func recordAttempt() {
      attemptCount += 1
    }

    func recordCancellation() {
      cancellationCount += 1
    }

    func recordSaved(_ profile: Profile) {
      savedLabels.append(profile.label)
      savedCurrencyCodes.append(profile.currencyCode)
    }
  }
}

import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("Tax owner edit submission")
struct TaxOwnerEditSubmissionTests {
  @Test("submit ignores duplicate taps while save is in flight")
  func submitIgnoresDuplicateTapsWhileSaveIsInFlight() async {
    let store = TaxOwnerEditSubmissionStore()
    let gate = Gate()
    let recorder = SubmissionRecorder()

    let firstSubmit = Task { @MainActor in
      await store.submit(
        name: "Family Trust",
        kind: .trust,
        save: { name, kind in
          recorder.recordSave(name: name, kind: kind)
          await gate.wait()
        },
        dismiss: { recorder.recordDismiss() })
    }

    while recorder.saveCount == 0 { await Task.yield() }

    await store.submit(
      name: "Family Trust",
      kind: .trust,
      save: { name, kind in
        recorder.recordSave(name: name, kind: kind)
      },
      dismiss: { recorder.recordDismiss() })

    #expect(recorder.saveCount == 1)
    await gate.open()
    await firstSubmit.value
    #expect(recorder.dismissCount == 1)
  }

  @Test("failed submit resets state so the user can try again")
  func failedSubmitResetsStateSoUserCanTryAgain() async {
    let store = TaxOwnerEditSubmissionStore()
    let recorder = SubmissionRecorder()

    await store.submit(
      name: "Family Trust",
      kind: .trust,
      save: { name, kind in
        recorder.recordSave(name: name, kind: kind)
        throw TaxOwnerStoreError.emptyName
      },
      dismiss: { recorder.recordDismiss() })

    #expect(store.isSubmitting == false)
    #expect(store.errorMessage == "Enter a tax owner name.")

    await store.submit(
      name: "Family Trust",
      kind: .trust,
      save: { name, kind in
        recorder.recordSave(name: name, kind: kind)
      },
      dismiss: { recorder.recordDismiss() })

    #expect(recorder.saveCount == 2)
    #expect(recorder.dismissCount == 1)
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

  @MainActor
  private final class SubmissionRecorder {
    private(set) var saveCount = 0
    private(set) var dismissCount = 0

    func recordSave(name _: String, kind _: TaxOwnerKind) {
      saveCount += 1
    }

    func recordDismiss() {
      dismissCount += 1
    }
  }
}

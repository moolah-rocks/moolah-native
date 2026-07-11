import Foundation

@MainActor
final class CloudKitProfileMetadataSaveStore {
  typealias UpdateProfile = @MainActor ((inout Profile) -> Void) async throws -> Profile?

  private let updateProfile: UpdateProfile
  private let onError: @MainActor (Error) -> Void
  private var latestSaveTask: Task<Void, Never>?
  private var saveTasks: [Task<Void, Never>] = []

  init(
    updateProfile: @escaping UpdateProfile,
    onError: @escaping @MainActor (Error) -> Void
  ) {
    self.updateProfile = updateProfile
    self.onError = onError
  }

  deinit {
    MainActor.assumeIsolated {
      cancelPendingSaves()
    }
  }

  func scheduleSave(
    label: String,
    currencyCode: String,
    financialYearStartMonth: Int
  ) {
    let previousSave = latestSaveTask
    let saveTask = Task { @MainActor [previousSave, updateProfile, onError] in
      await previousSave?.value
      guard !Task.isCancelled else { return }

      do {
        _ = try await updateProfile { profile in
          profile.label = label
          profile.currencyCode = currencyCode
          profile.financialYearStartMonth = financialYearStartMonth
        }
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled else { return }
        onError(error)
      }
    }
    latestSaveTask = saveTask
    saveTasks.append(saveTask)

    Task { @MainActor [weak self, saveTask] in
      await saveTask.value
      self?.saveTasks.removeAll { $0 == saveTask }
      if self?.latestSaveTask == saveTask {
        self?.latestSaveTask = nil
      }
    }
  }

  func cancelPendingSaves() {
    latestSaveTask?.cancel()
    for task in saveTasks {
      task.cancel()
    }
  }

  func waitForPendingSaves() async {
    let tasks = saveTasks
    for task in tasks {
      await task.value
    }
  }
}

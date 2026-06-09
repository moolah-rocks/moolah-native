import Foundation
import Testing

@testable import Moolah

@Suite("AnalysisStore — load cancellation")
@MainActor
struct AnalysisStoreLoadCancellationTests {

  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "com.moolah.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  /// A `loadAll()` cancelled mid-fetch must NOT surface
  /// `CancellationError` on `store.error`. `AnalysisView`'s `.task` is
  /// routinely cancelled during cold-launch state restoration and when
  /// navigating between sidebar items. Because `AnalysisStore` is owned
  /// by `ProfileSession`, a leaked `CancellationError` persists past
  /// the view tear-down and renders "Swift.CancellationError error 1"
  /// on the next mount.
  @Test
  func cancelledLoadAllDoesNotSurfaceCancellationError() async throws {
    let repository = GatedAnalysisRepository()
    let store = AnalysisStore(
      repository: repository, conversionService: StubConversionService(),
      defaults: try makeDefaults())

    let task = Task { @MainActor in
      await store.loadAll()
    }
    await repository.waitUntilFetchStarted()
    task.cancel()
    await repository.releaseFetch()
    await task.value

    #expect(store.error == nil)
    #expect(!store.isLoading)
  }
}

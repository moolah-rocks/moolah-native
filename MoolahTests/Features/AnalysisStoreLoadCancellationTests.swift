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

  /// A rate tick that coalesces into a pending reconcile while the initial
  /// load is in flight must NOT run after the owning task is cancelled.
  /// Without the `Task.isCancelled` guard in `loadAll`'s coalescing loop,
  /// the trailing reconcile would issue a second wasted fetch on a
  /// torn-down view and restamp `lastLoadedAt`. See #1163.
  @Test
  func cancellationDuringInitialLoadSkipsCoalescedReconcile() async throws {
    let repository = GatedCountingAnalysisRepository()
    let store = AnalysisStore(
      repository: repository, conversionService: StubConversionService(),
      defaults: try makeDefaults())

    let task = Task { @MainActor in await store.loadAll() }
    await repository.waitUntilFetchStarted()
    // A rate tick lands during the in-flight initial load → coalesced into
    // a single pending reconcile pass.
    await store.reloadForRateTick()
    // The view tears down before the initial load completes.
    task.cancel()
    await repository.releaseAll()
    await task.value

    // Only the initial fetch ran; the coalesced reconcile was skipped.
    let count = await repository.loadAllCount
    #expect(count == 1)
    #expect(store.error == nil)
    #expect(!store.isLoading)
  }
}

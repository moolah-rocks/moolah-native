import SwiftUI

extension View {
  /// Injects a `ProfileStore`, `ProfileSession`, and the session's
  /// `ImportStore` into the view hierarchy for `#Preview` use. Required by
  /// views that use `.profileNavigationTitle(...)` or `TransactionListView`.
  ///
  /// Defaults to no-profile preview environments. Pass an explicit
  /// `profileStore` (e.g. `ProfileStore.preview(profiles: [fixture])`)
  /// to exercise the multi-profile branch of `profileNavigationTitle`.
  @MainActor
  func previewProfileEnvironment(
    session: ProfileSession? = nil,
    profileStore: ProfileStore = ProfileStore.preview()
  ) -> some View {
    let resolvedSession: ProfileSession
    if let session {
      resolvedSession = session
    } else {
      // In-memory preview session can't fail in practice: opens an
      // ephemeral GRDB queue with no disk access. A trap here is
      // acceptable in #Preview.
      // swiftlint:disable:next force_try
      resolvedSession = try! ProfileSession.preview()
    }
    return
      self
      .environment(profileStore)
      .environment(resolvedSession)
      .environment(resolvedSession.importStore)
  }
}

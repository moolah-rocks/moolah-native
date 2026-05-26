import SwiftUI

/// Injects all stores from a ProfileSession into the environment, then shows AppRootView.
/// The `.id(session.id)` forces a full view hierarchy rebuild on profile switch.
struct SessionRootView: View {
  @Bindable var session: ProfileSession

  var body: some View {
    AppRootView()
      .id(session.id)
      .environment(session)
      .environment(session.authStore)
      .environment(session.accountStore)
      .environment(session.transactionStore)
      .environment(session.categoryStore)
      .environment(session.earmarkStore)
      .environment(session.accountGroupStore)
      .environment(session.analysisStore)
      .environment(session.investmentStore)
      .environment(session.reportingStore)
      .environment(session.importStore)
      .environment(session.importRuleStore)
      .modifier(
        HandoffPublisherModifier(
          profileID: session.profile.id,
          accountLookup: session.accountStore,
          earmarkLookup: session.earmarkStore)
      )
      .focusedSceneValue(\.authStore, session.authStore)
      .focusedSceneValue(\.activeProfileSession, session)
      .sheet(item: $session.activeExport) { active in
        ExportProgressSheet(
          profileLabel: active.profileLabel,
          stageLabel: active.stageLabel
        )
        .interactiveDismissDisabled()
      }
      .task(id: session.id) {
        // Crypto-wallet auto-import bootstrap: hydrate observable
        // checkpoint state from disk, then run the launch-time stale
        // sync. Cancellation of this `.task` fires when the session
        // changes (the `.id(session.id)` modifier forces a rebuild on
        // profile switch); the store's per-account work cooperatively
        // cancels via `Task.checkCancellation` inside the engines.
        guard let cryptoSyncStore = session.cryptoSyncStore else { return }
        await cryptoSyncStore.loadInitialState()
        await cryptoSyncStore.syncStaleAccounts()
      }
  }
}

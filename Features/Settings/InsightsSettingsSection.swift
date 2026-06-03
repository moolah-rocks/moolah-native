import SwiftUI

/// Settings controls for the personalized-insights narration layer. Embedded by
/// both platform Settings layouts only when the model is usable — the whole
/// view is omitted on ineligible devices so the feature is invisible where it
/// can never run (issue #1030 Phase E: "ships nothing to ineligible devices").
///
/// Both toggles are stored as `@AppStorage` keys in the default suite,
/// matching the `showHiddenAccounts` / `showSpamTransactions` precedent in
/// `SidebarView`. The weekly-recap toggle is opt-in (default off); the
/// narration master switch defaults on (only shown when the device is eligible).
struct InsightsSettingsSection: View {
  @AppStorage("insightsNarrationEnabled") private var narrationEnabled = true
  @AppStorage("weeklyRecapEnabled") private var recapEnabled = false

  var body: some View {
    Section("Insights") {
      Toggle("Explain insights with Apple Intelligence", isOn: $narrationEnabled)
      Toggle("Show a weekly recap", isOn: $recapEnabled)
        .disabled(!narrationEnabled)
    }
  }
}

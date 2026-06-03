import SwiftUI

/// Settings controls for the personalized-insights narration layer. Embedded by
/// both platform Settings layouts only when the model is usable — the whole
/// view is omitted on ineligible devices so the feature is invisible where it
/// can never run (issue #1030).
///
/// Both toggles are stored as `@AppStorage` keys in the `moolahShared` suite
/// so they are scoped to the current CloudKit environment. The weekly-recap
/// toggle is opt-in (default off); the narration master switch defaults on
/// (only shown when the device is eligible).
struct InsightsSettingsSection: View {
  // `@AppStorage` requires a string literal, so the constant from
  // `UserDefaults.insightsNarrationEnabledKey` is aliased here to satisfy
  // swift-format's line-length limit without duplicating the raw string.
  private static let narrationKey = UserDefaults.insightsNarrationEnabledKey
  @AppStorage(narrationKey, store: .moolahShared) private var narrationEnabled = true
  @AppStorage("weeklyRecapEnabled", store: .moolahShared) private var recapEnabled = false

  var body: some View {
    Section {
      Toggle("Explain insights with on-device AI", isOn: $narrationEnabled)
      Toggle("Weekly recap", isOn: $recapEnabled)
        .disabled(!narrationEnabled)
    } header: {
      Text("Insights")
    } footer: {
      Text(
        narrationEnabled
          ? "Explanations are generated on your device and never leave it."
          : "Turn on insight explanations to enable the weekly recap.")
    }
  }
}

#if DEBUG
  #Preview {
    Form {
      InsightsSettingsSection()
    }
    .formStyle(.grouped)
  }
#endif

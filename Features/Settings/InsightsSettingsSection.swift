import SwiftUI

/// Settings controls for the personalized-insights narration layer. Embedded by
/// both platform Settings layouts only when the model is usable — the whole
/// view is omitted on ineligible devices so the feature is invisible where it
/// can never run (issue #1030).
///
/// The toggle is stored as an `@AppStorage` key in the `moolahShared` suite
/// so it is scoped to the current CloudKit environment. The narration master
/// switch defaults on (only shown when the device is eligible).
struct InsightsSettingsSection: View {
  // `@AppStorage` requires a string literal, so the constant from
  // `UserDefaults.insightsNarrationEnabledKey` is aliased here to satisfy
  // swift-format's line-length limit without duplicating the raw string.
  private static let narrationKey = UserDefaults.insightsNarrationEnabledKey
  @AppStorage(narrationKey, store: .moolahShared) private var narrationEnabled = true

  var body: some View {
    Section {
      Toggle("Explain insights with on-device AI", isOn: $narrationEnabled)
    } header: {
      Text("Insights")
    } footer: {
      Text("Explanations are generated on your device and never leave it.")
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

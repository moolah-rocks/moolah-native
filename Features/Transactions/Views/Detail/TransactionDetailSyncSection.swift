import SwiftUI

/// "Synced from …" row at the foot of the transaction detail for a
/// transaction that background sync created. Shown in the non-custom views
/// (income / expense / transfer / trade / earmark-only); the custom multi-leg
/// view instead marks each synced leg's section header. Hidden when no leg
/// came from background sync.
struct TransactionDetailSyncSection: View {
  /// The distinct background-sync sources across the transaction's synced
  /// legs. A merged wallet↔exchange transfer contributes both.
  let sources: Set<BackgroundSyncSource>

  var body: some View {
    if !sources.isEmpty {
      Section {
        Label(Self.label(for: sources), systemImage: "arrow.triangle.2.circlepath")
          .foregroundStyle(.secondary)
          .accessibilityLabel(Self.label(for: sources))
          .accessibilityIdentifier(UITestIdentifiers.Detail.syncOrigin)
      }
    }
  }

  /// "Synced from Wallet" for one source, "Synced from Wallet and Coinstash"
  /// for two. Names follow `BackgroundSyncSource`'s declaration order (a
  /// deterministic, product-defined order) and are joined with a localized
  /// list conjunction.
  nonisolated static func label(for sources: Set<BackgroundSyncSource>) -> String {
    let names = BackgroundSyncSource.allCases
      .filter { sources.contains($0) }
      .map(\.displayName)
    let joined = ListFormatter.localizedString(byJoining: names)
    return "Synced from \(joined)"
  }
}

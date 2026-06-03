import SwiftUI

/// Dismissible card that shows the weekly recap narration above the
/// "For You" panel on the Analysis surface. Rendered only when the
/// `WeeklyRecapStore` is in `.preparing` or `.ready` state — the caller
/// guards on this before including the card in the hierarchy.
///
/// This is a thin presentational view: all state lives in
/// `WeeklyRecapStore`; this view binds the recap state and dispatches
/// the dismiss closure (issue #1042).
struct WeeklyRecapCard: View {
  let recap: RecapState
  let onDismiss: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("Your week")
          .font(.title2)
          .fontWeight(.semibold)
          .accessibilityIdentifier(UITestIdentifiers.WeeklyRecap.card)
        Spacer(minLength: 8)
        Button(action: onDismiss) {
          Image(systemName: "xmark.circle.fill")
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        #if os(iOS)
          .frame(minWidth: 44, minHeight: 44)
        #endif
        .help("Dismiss weekly recap")
        .accessibilityLabel("Dismiss weekly recap")
        .accessibilityIdentifier(UITestIdentifiers.WeeklyRecap.dismiss)
      }
      recapContent
    }
    .padding()
    .background(.background)
    .clipShape(.rect(cornerRadius: 12))
  }

  @ViewBuilder private var recapContent: some View {
    switch recap {
    case .hidden:
      EmptyView()
    case .preparing:
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Putting together your week…")
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    case .ready(let text):
      Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}

#if DEBUG
  #Preview("Preparing") {
    WeeklyRecapCard(recap: .preparing, onDismiss: {})
      .padding()
      .frame(width: 420)
  }

  #Preview("Ready") {
    WeeklyRecapCard(
      recap: .ready(
        "This week your net worth crossed $100k and your dining spend stayed "
          + "within your usual range of $410."),
      onDismiss: {}
    )
    .padding()
    .frame(width: 420)
  }
#endif

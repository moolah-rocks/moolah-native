import SwiftUI

/// A detected transfer pair pending a user "not a transfer" confirmation.
struct RecentlyAddedTransferPair: Identifiable {
  let transaction: Transaction
  let counterpart: Transaction
  var id: UUID { transaction.id }
}

/// iOS leading-swipe equivalents of the transfer context-menu actions.
/// macOS uses the context menu only, so the modifier is a no-op there.
struct TransferSwipeActions: ViewModifier {
  let counterpart: Transaction?
  let onMerge: () -> Void
  let onDismiss: () -> Void
  let mergeIdentifier: String
  let dismissIdentifier: String

  func body(content: Content) -> some View {
    #if os(iOS)
      content.swipeActions(edge: .leading) {
        if counterpart != nil {
          Button(action: onMerge) {
            Label("Merge as Transfer", systemImage: "arrow.left.arrow.right")
          }
          .tint(.blue)
          .accessibilityIdentifier(mergeIdentifier)
          Button(role: .destructive, action: onDismiss) {
            Label("Not a Transfer", systemImage: "xmark")
          }
          .accessibilityIdentifier(dismissIdentifier)
        }
      }
    #else
      content
    #endif
  }
}

/// Passive "possible transfer" badge. No tap affordance — the merge /
/// dismiss actions live in the row's context menu (macOS) and leading
/// swipe (iOS). Matches the "Needs review" capsule's shape and metrics
/// with the transfer-icon semantic colour.
private struct PossibleTransferPill: View {
  let title: String

  var body: some View {
    Label {
      Text(title)
        .lineLimit(1)
        .truncationMode(.tail)
    } icon: {
      Image(systemName: "arrow.left.arrow.right")
    }
    .font(.caption2)
    .layoutPriority(-1)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(Color.blue.opacity(0.15), in: Capsule())
    .foregroundStyle(Color.blue)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
  }
}

/// Row for one imported transaction. Shows date, description, amount, a
/// "Needs review" badge when all legs are uncategorised, and a passive
/// "possible transfer" pill when a `TransferSuggestion` record touches
/// the transaction. `hasSuggestion`, `pillTitle`, and
/// `accessibilityLabel` are all resolved by `RecentlyAddedViewModel`
/// from the synced-record snapshot — the row stays a thin renderer and
/// never reads the repository or a denormalised model field.
struct RecentlyAddedRow: View {
  let transaction: Transaction
  let hasSuggestion: Bool
  let pillTitle: String
  let accessibilityLabel: String

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(transaction.payee ?? transaction.importOrigin?.singleOrigin?.rawDescription ?? "")
          .lineLimit(1)
        Text(transaction.date, format: .dateTime.day().month().year())
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      .layoutPriority(1)
      Spacer()
      if let primary = displayAmount {
        InstrumentAmountView(amount: primary, font: .body)
      }
      if hasSuggestion {
        PossibleTransferPill(title: pillTitle)
      }
      if transaction.needsReview {
        Text("Needs review")
          .font(.caption2)
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(Color.orange.opacity(0.15), in: Capsule())
          .foregroundStyle(Color.orange)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("Needs review")
      }
    }
    .padding(.vertical, 2)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityLabel)
    .accessibilityHint(actionHint)
  }

  /// Discoverability hint for the secondary transfer actions. Empty for
  /// rows without a transfer suggestion — those carry no transfer actions,
  /// so VoiceOver announces no hint. macOS surfaces the actions in the
  /// context menu; iOS surfaces the leading swipe, which VoiceOver
  /// announces on its own, so the hint stays generic.
  private var actionHint: String {
    guard hasSuggestion else { return "" }
    #if os(macOS)
      return "Transfer actions are available in the context menu"
    #else
      return "Transfer actions available"
    #endif
  }

  /// Pick the first leg (the source/cash leg from the importer) and build
  /// an `InstrumentAmount` so colour coding + per-instrument formatting
  /// come straight from `InstrumentAmountView`. Cross-instrument transfers
  /// intentionally show only the source-side amount here; the detail view
  /// lists both legs.
  private var displayAmount: InstrumentAmount? {
    guard let leg = transaction.legs.first else { return nil }
    return InstrumentAmount(quantity: leg.quantity, instrument: leg.instrument)
  }
}

#Preview("Transfer suggestion") {
  let suggested = Transaction(
    date: Date(),
    payee: "Transfer to Savings",
    legs: [
      TransactionLeg(
        accountId: UUID(), instrument: .AUD, quantity: -500, type: .expense)
    ])
  return List {
    RecentlyAddedRow(
      transaction: suggested,
      hasSuggestion: true,
      pillTitle: "Possible transfer to Savings",
      accessibilityLabel: "Transfer to Savings, 1 Jan 2026, -$500.00, "
        + "Possible transfer to Savings, Needs review")
  }
}

#Preview("Plain row and pill plus needs-review") {
  let categorised = TransactionLeg(
    accountId: UUID(),
    instrument: .AUD,
    quantity: -42,
    type: .expense,
    categoryId: UUID())
  let plain = Transaction(date: Date(), payee: "Grocery Store", legs: [categorised])
  let pillAndReview = Transaction(
    date: Date(),
    payee: "Transfer to a Long-Named Investment Account",
    legs: [
      TransactionLeg(
        accountId: UUID(), instrument: .AUD, quantity: -1200, type: .expense)
    ])
  return List {
    RecentlyAddedRow(
      transaction: plain,
      hasSuggestion: false,
      pillTitle: "Possible transfer",
      accessibilityLabel: "Grocery Store, 1 Jan 2026, -$42.00")
    RecentlyAddedRow(
      transaction: pillAndReview,
      hasSuggestion: true,
      pillTitle: "Possible transfer to Long-Named Investment Account",
      accessibilityLabel: "Transfer to a Long-Named Investment Account, "
        + "1 Jan 2026, -$1,200.00, "
        + "Possible transfer to Long-Named Investment Account, Needs review")
  }
}

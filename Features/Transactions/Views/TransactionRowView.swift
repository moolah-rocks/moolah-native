import SwiftUI

struct TransactionRowView: View {
  let transaction: Transaction
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let displayAmounts: [InstrumentAmount]
  let balance: InstrumentAmount?
  let scopeReferenceInstrument: Instrument
  var hideEarmark: Bool = false
  /// Perspective the row's description / metadata renders from. Derived
  /// per-row by the parent from the view's `accountIds` set: exactly one
  /// in-scope leg → that leg's account; otherwise → nil (no-context style).
  /// nil for scheduled / all-accounts views and for group-view rows that
  /// touch multiple members.
  var accountContext: UUID?

  /// When true, the payee header shows a red `exclamationmark.triangle.fill`
  /// leading icon and the payee text renders in red. Used by the
  /// `.scheduledStatus` grouping for overdue rows.
  var isOverdue: Bool = false

  /// When true, the date in the meta row renders in orange and bold,
  /// indicating the scheduled transaction is due today. Used by the
  /// `.scheduledStatus` grouping.
  var isDueToday: Bool = false

  /// Optional inline Pay button. When non-nil, the row renders a trailing
  /// "Pay" button that invokes the closure. When nil (the default), no
  /// button is rendered. Used by the `.scheduledStatus` grouping.
  var onPay: (() -> Void)?

  /// When non-nil and equal to this row's transaction id, the inline Pay
  /// area is replaced by a small `ProgressView` with a payee-parameterised
  /// `.accessibilityLabel`, and the row is `.disabled(true)`. Used by the
  /// `.scheduledStatus` grouping for the in-progress pay flow.
  var pendingPayId: Transaction.ID?

  #if os(macOS)
    @ScaledMetric private var verticalPadding: CGFloat = 8
  #else
    @ScaledMetric private var verticalPadding: CGFloat = 12
  #endif

  // `internal` so the leading-icon helpers in the `+Icon.swift` extension
  // can read the env-injected spam set when computing `rowIsSpam`.
  @Environment(\.spamInstruments) var spamInstruments

  // MARK: - Body & View Builders

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      typeIconWithSpamBadge
      infoColumn
      Spacer()
      amountColumn
        .opacity(rowIsSpam ? 0.5 : 1.0)
      payAffordance
    }
    .padding(.vertical, verticalPadding)
    .disabled(isPaying)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityDescription)
  }

  // MARK: - Title

  private var infoColumn: some View {
    VStack(alignment: .leading, spacing: 2) {
      titleRow
        .opacity(rowIsSpam ? 0.5 : 1.0)
      metadataRow
    }
  }

  private var titleRow: some View {
    HStack(spacing: 4) {
      if isOverdue {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.red)
          .imageScale(.small)
          .accessibilityHidden(true)
      }
      titleTextValue
        .lineLimit(1)
        .foregroundStyle(isOverdue ? Color.red : Color.primary)
    }
  }

  /// Composed title for the row. Trade transactions show the
  /// "Bought 100 SCAM" / "Sold X" / "Swapped X for Y" sentence. Spam-flagged
  /// legs render their symbol with an inline yellow octagon badge + strike-
  /// through (see `TradeTitleSegment.text`) so the reader is warned not to
  /// trust the claimed name (e.g. a fake "USDC").
  private var titleTextValue: Text {
    let payee = displayPayee
    if let sentence = transaction.tradeTitleText(
      scopeReference: scopeReferenceInstrument,
      spamInstruments: spamInstruments
    ) {
      if payee.isEmpty {
        return sentence
      }
      return Text("\(payee) (\(sentence))")
    }
    return Text(payee)
  }

  /// Plain-string equivalent of the title used by `accessibilityDescription`.
  /// Spam-flagged legs still read as "<magnitude> spam token" via
  /// `accessibilityString` so VoiceOver users get an audible signal even
  /// though the visual treatment relies on grey-out + leading icon.
  private var titleAccessibilityString: String {
    let payee = displayPayee
    let segments = transaction.tradeTitleSegments(
      scopeReference: scopeReferenceInstrument,
      spamInstruments: spamInstruments)
    guard !segments.isEmpty else { return payee }
    let sentence = segments.map(\.accessibilityString).joined()
    return payee.isEmpty ? sentence : "\(payee) (\(sentence))"
  }

  // MARK: - Metadata Row

  private var metadataRow: some View {
    HStack(spacing: 4) {
      Text(transaction.date, format: .dateTime.day().month(.abbreviated).year())
        .foregroundStyle(isDueToday ? Color.orange : Color.secondary)
        .fontWeight(isDueToday ? .semibold : .regular)
        .monospacedDigit()
      if let recurrence = recurrenceDescription {
        Text("·")
        Text(recurrence)
      }
      ForEach(categoryNames, id: \.self) { name in
        Text("·")
        Label(name, systemImage: "tag")
          .labelStyle(.iconOnly)
          .imageScale(.small)
        Text(name)
      }
      if !hideEarmark {
        ForEach(earmarkNames, id: \.self) { name in
          Text("·")
          Label(name, systemImage: "bookmark.fill")
            .labelStyle(.iconOnly)
            .imageScale(.small)
          Text(name)
        }
      }
    }
    // `.caption` (not `.subheadline`) is a deliberate exception to the style guide:
    // the smaller font is the intended look for this metadata row. Don't "fix" it.
    .font(.caption)
    .foregroundStyle(.secondary)
  }

  @ViewBuilder private var payAffordance: some View {
    if isPaying {
      ProgressView()
        .controlSize(.small)
        .accessibilityLabel("Paying \(displayPayee), please wait")
    } else if let onPay {
      Button("Pay") { onPay() }
        #if os(iOS)
          .buttonStyle(.borderedProminent)
          .controlSize(.regular)
        #else
          .buttonStyle(.bordered)
          .controlSize(.small)
        #endif
        .accessibilityLabel("Pay \(displayPayee)")
    }
  }

  // MARK: - Computed Display Properties

  private var isPaying: Bool {
    pendingPayId != nil && pendingPayId == transaction.id
  }

  private var recurrenceDescription: String? {
    guard let period = transaction.recurPeriod,
      let every = transaction.recurEvery,
      period != .once
    else {
      return nil
    }
    return period.recurrenceDescription(every: every)
  }

  // MARK: - Amount Column

  private var amountColumn: some View {
    VStack(alignment: .trailing, spacing: 2) {
      if displayAmounts.isEmpty {
        Text("—")
          .font(.body)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      } else {
        TransactionAmountFlow(amounts: displayAmounts)
      }
      if let balance {
        InstrumentAmountView(amount: balance, font: .caption)
      }
    }
  }

  // MARK: - Accessibility

  private var accessibilityDescription: String {
    let dateStr = transaction.date.formatted(date: .abbreviated, time: .omitted)
    let amountStr =
      displayAmounts.isEmpty
      ? "amount unavailable"
      : displayAmounts
        .map { $0.accessibilityString(isSpam: spamInstruments.contains($0.instrument)) }
        .joined(separator: " and ")
    let typeStr: String
    if transaction.isTrade {
      typeStr = TransactionType.trade.displayName
    } else if transaction.isSimple, let type = transaction.legs.first?.type {
      typeStr = type.displayName
    } else {
      typeStr = "Custom transaction"
    }
    var parts: [String] = []
    if isOverdue {
      parts.append("Overdue")
    }
    parts.append(typeStr)
    parts.append(titleAccessibilityString)
    parts.append(amountStr)
    if isDueToday {
      parts.append("due today, \(dateStr)")
    } else {
      parts.append(dateStr)
    }
    if let balance {
      parts.append(
        "balance \(balance.accessibilityString(isSpam: spamInstruments.contains(balance.instrument)))"
      )
    }
    if let recurrence = recurrenceDescription {
      parts.append("repeats \(recurrence)")
    }
    return parts.joined(separator: ", ")
  }

  private var categoryNames: [String] {
    let applicable =
      accountContext.map { id in
        transaction.legs.filter { $0.accountId == id }
      } ?? transaction.legs
    let uniqueIds = applicable.compactMap(\.categoryId).uniqued()
    return uniqueIds.compactMap { id in categories.by(id: id).map { categories.path(for: $0) } }
  }

  private var earmarkNames: [String] {
    let applicable =
      accountContext.map { id in
        transaction.legs.filter { $0.accountId == id }
      } ?? transaction.legs
    let uniqueIds = applicable.compactMap(\.earmarkId).uniqued()
    return uniqueIds.compactMap { earmarks.by(id: $0)?.name }
  }

  private var displayPayee: String {
    transaction.displayPayee(
      accountContext: accountContext, accounts: accounts, earmarks: earmarks)
  }

}

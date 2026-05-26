import SwiftUI

/// Sums per-instrument quantities across the supplied account ids,
/// preserving first-seen order. Members holding the same instrument
/// coalesce to one row; multi-instrument groups expose a row per
/// instrument. Pure (no actor isolation) so it can be unit-tested
/// without instantiating the SwiftUI view.
func aggregatedGroupPositions(
  across accountIds: [UUID], in accounts: Accounts
) -> [Position] {
  var sums: [Instrument: Decimal] = [:]
  var order: [Instrument] = []
  for id in accountIds {
    guard let account = accounts.by(id: id) else { continue }
    for position in account.positions {
      if sums[position.instrument] == nil {
        order.append(position.instrument)
      }
      sums[position.instrument, default: 0] += position.quantity
    }
  }
  return order.compactMap { instrument in
    guard let quantity = sums[instrument] else { return nil }
    return Position(instrument: instrument, quantity: quantity)
  }
}

/// Composite detail view for an `AccountGroup`. Renders the group's
/// aggregated balance + merged transactions + multi-instrument position
/// totals across every member.
///
/// Binds to an `AccountViewContext` rather than reading an `Account`
/// directly. The header, positions split, and transaction list all
/// consume `context.accountIds`; this view never knows whether the
/// context came from a group or a single account — both shapes are
/// supported (a 1-element accountIds list collapses to the same code
/// path).
///
/// New Transaction defaults to the first id in `accountIds` per spec
/// §"Composite detail view → Header" — the user can change the
/// destination in the transaction-detail panel's account picker.
struct GroupDetailView: View {
  let context: AccountViewContext
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  let conversionService: any InstrumentConversionService

  @Environment(AccountStore.self) private var accountStore

  /// Cached aggregate balance for the current `accountIds` set,
  /// recomputed when membership changes. `nil` either before the first
  /// compute completes or when conversion failed for any member (per
  /// `feedback_conversion_failure_ux` — never partial-sum).
  @State private var aggregateBalance: InstrumentAmount?

  var body: some View {
    let aggregatedPositions = aggregatedGroupPositions(
      across: context.accountIds, in: accounts)

    TransactionListView(
      title: context.displayName,
      filter: TransactionFilter(accountIds: Set(context.accountIds)),
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore
    )
    .safeAreaInset(edge: .top, spacing: 0) {
      headerCard
    }
    .multiInstrumentPositionsSplit(
      positions: aggregatedPositions,
      hostCurrency: context.displayInstrument,
      title: context.displayName,
      conversionService: conversionService
    )
    .task(id: context.accountIds) {
      await refreshAggregateBalance()
    }
  }

  // MARK: - Header

  /// Header card with the group name + aggregate balance. The full
  /// rich header (rename affordance, sync-status popover, conversion-
  /// failure breakdown) is deferred to a follow-up — Phase 5's
  /// acceptance criterion is that the balance respects the conversion-
  /// failure UX (unavailable, never partial-sum), which this view
  /// honours by rendering an "Unavailable" badge when
  /// `aggregateBalance` is nil after the compute finishes.
  @ViewBuilder private var headerCard: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(context.displayName)
        .font(.title2.weight(.semibold))
      balanceLabel
      syncStatusLabel
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal)
    .padding(.vertical, 8)
    .background(.bar)
  }

  @ViewBuilder private var balanceLabel: some View {
    if let amount = aggregateBalance {
      Text(amount.formatted)
        .font(.title.weight(.semibold))
        .monospacedDigit()
    } else {
      Text("Unavailable")
        .font(.title3.weight(.semibold))
        .foregroundStyle(.secondary)
        .accessibilityLabel("Aggregate balance unavailable")
    }
  }

  @ViewBuilder private var syncStatusLabel: some View {
    switch context.syncStatus {
    case .allSynced:
      EmptyView()
    case let .syncing(done, total):
      Label("Syncing \(done) of \(total)", systemImage: "arrow.triangle.2.circlepath")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .failed(let memberIds):
      Label(
        "\(memberIds.count) member\(memberIds.count == 1 ? "" : "s") failed",
        systemImage: "exclamationmark.triangle.fill"
      )
      .font(.caption)
      .foregroundStyle(.red)
    }
  }

  // MARK: - Aggregation helpers

  private func refreshAggregateBalance() async {
    do {
      aggregateBalance = try await accountStore.aggregateBalance(
        for: context.accountIds, in: context.displayInstrument)
    } catch {
      aggregateBalance = nil
    }
  }
}

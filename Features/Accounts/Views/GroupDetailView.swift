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
/// directly. The positions split and transaction list both consume
/// `context.accountIds`; this view never knows whether the context came
/// from a group or a single account — both shapes are supported (a
/// 1-element accountIds list collapses to the same code path).
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
    .multiInstrumentPositionsSplit(
      positions: aggregatedPositions,
      hostCurrency: context.displayInstrument,
      title: context.displayName,
      conversionService: conversionService,
      accountIds: context.accountIds
    )
  }
}

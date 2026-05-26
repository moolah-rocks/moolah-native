import SwiftUI

/// View wrapper that keeps an `AccountGroup`'s aggregate balance
/// refreshed and threads it into its content closure. Owns the
/// `@State InstrumentAmount?` cache + the `.task(id:)` that recomputes
/// via `AccountStore.aggregateBalance(for:in:)` whenever the member
/// set or target instrument changes. A conversion failure on any
/// member surfaces as `nil` (per `feedback_conversion_failure_ux.md` —
/// never partial-sum); the content view renders a spinner / badge in
/// that case.
///
/// Used by `SidebarView+Groups.groupRowLink` to wire the sidebar row's
/// `aggregateBalance` parameter, and reusable from any future call
/// site that needs a refreshable group total (e.g. an account picker
/// that wants to show a group's total alongside its name).
struct GroupAggregateBalanceLoader<Content: View>: View {
  let memberIds: [UUID]
  let targetInstrument: Instrument
  @ViewBuilder var content: (InstrumentAmount?) -> Content

  @Environment(AccountStore.self) private var accountStore
  @State private var balance: InstrumentAmount?

  /// `.task(id:)` key — recomputes when the member set OR the target
  /// instrument changes. Hashable so SwiftUI can compare it.
  private struct Key: Hashable {
    let memberIds: [UUID]
    let targetInstrument: Instrument
  }

  var body: some View {
    content(balance)
      .task(id: Key(memberIds: memberIds, targetInstrument: targetInstrument)) {
        await refresh()
      }
  }

  private func refresh() async {
    do {
      balance = try await accountStore.aggregateBalance(
        for: memberIds, in: targetInstrument)
    } catch {
      // Per feedback_conversion_failure_ux: never partial-sum on
      // failure. nil renders the sidebar's loading / unavailable slot.
      balance = nil
    }
  }
}

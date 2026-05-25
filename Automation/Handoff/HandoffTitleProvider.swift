import Foundation

/// Read-only window into account display names. Implemented by the real
/// `AccountStore` and by fakes in tests. `@MainActor` so the real store's
/// main-actor-isolated `accounts` snapshot can satisfy it without crossing
/// actor boundaries; the title provider runs from MainActor view code.
@MainActor
protocol HandoffAccountLookup {
  func displayName(for id: UUID) -> String?
}

/// Read-only window into earmark display names. Implemented by the real
/// `EarmarkStore` and by fakes in tests. `@MainActor` for the same reason
/// as `HandoffAccountLookup`.
@MainActor
protocol HandoffEarmarkLookup {
  func displayName(for id: UUID) -> String?
}

/// Pure function that turns a `NavigationDestination` into the
/// human-readable title shown in the Handoff badge / Dock icon.
///
/// Lookups are passed in as protocols so the function is testable
/// without standing up a real store. Account / earmark names are looked
/// up by id; missing names fall back to a generic "Account" / "Earmark"
/// rather than embedding the UUID, which would be unhelpful in the UI.
enum HandoffTitleProvider {

  @MainActor
  static func title(
    for destination: NavigationDestination,
    accounts: HandoffAccountLookup,
    earmarks: HandoffEarmarkLookup
  ) -> String {
    switch destination {
    case .accounts: "Accounts"
    case .account(let id): accounts.displayName(for: id) ?? "Account"
    case .transaction: "Transaction"
    case .earmarks: "Earmarks"
    case .earmark(let id): earmarks.displayName(for: id) ?? "Earmark"
    case .analysis: "Analysis"
    case .reports: "Reports"
    case .categories: "Categories"
    case .upcoming: "Upcoming"
    }
  }
}

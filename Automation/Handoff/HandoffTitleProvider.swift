import Foundation

/// Pure function that turns a `NavigationDestination` into the
/// human-readable title shown in the Handoff badge / Dock icon.
///
/// Lookups are passed in as protocols so the function is testable
/// without standing up a real store. Account / earmark names are looked
/// up by id; missing names fall back to a generic "Account" / "Earmark"
/// rather than embedding the UUID, which would be unhelpful in the UI.
enum HandoffTitleProvider {

  /// Returns the human-readable title for a navigation destination, used
  /// in the Handoff badge / Dock icon. Account / earmark titles look up
  /// the display name by id and fall back to the generic noun when the
  /// id is not present in the local store — embedding the UUID would be
  /// unhelpful in the UI.
  ///
  /// `@MainActor` because the lookup protocols (`HandoffAccountLookup`,
  /// `HandoffEarmarkLookup`) are main-actor-isolated to match their
  /// `AccountStore` / `EarmarkStore` conformers.
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

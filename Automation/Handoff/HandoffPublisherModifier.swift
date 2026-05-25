import Foundation
import SwiftUI

/// Reads the focused-scene navigation state and stamps an
/// `NSUserActivity` via SwiftUI's `.userActivity(_:isActive:_:)` so the
/// system can hand the route off to a peer device.
///
/// The account / earmark stores are passed in as explicit parameters
/// rather than read from `@Environment`. `@Environment` reads fire as
/// soon as the modifier is constructed; if the modifier is applied
/// outside the scope where the stores are injected (or before the
/// `.environment(...)` chain wraps it), the lookup traps. Threading the
/// stores in directly side-steps that ordering problem and keeps the
/// publisher applicable wherever the session is in scope.
struct HandoffPublisherModifier: ViewModifier {
  let profileID: UUID
  let accountLookup: any HandoffAccountLookup
  let earmarkLookup: any HandoffEarmarkLookup
  @FocusedValue(\.sidebarSelection) private var sidebarSelection
  @FocusedValue(\.selectedTransactionID) private var selectedTransactionID
  @FocusedValue(\.analysisRoute) private var analysisRoute
  @FocusedValue(\.reportsRoute) private var reportsRoute

  private var route: NavigationDestination? {
    // `sidebarSelection` is `Binding<SidebarSelection?>?`. Flatten via
    // `flatMap` on the outer optional to a plain `SidebarSelection?`.
    let sidebar = sidebarSelection.flatMap { $0.wrappedValue }
    return NavigationDestination.make(
      sidebar: sidebar,
      selectedTransaction: selectedTransactionID,
      analysis: analysisRoute,
      reports: reportsRoute)
  }

  func body(content: Content) -> some View {
    content.userActivity(
      HandoffActivity.continueActivityType,
      isActive: route != nil
    ) { activity in
      guard let route else { return }
      let payload = HandoffPayload(profileID: profileID, destination: route)
      let title = HandoffTitleProvider.title(
        for: route,
        accounts: accountLookup,
        earmarks: earmarkLookup)
      activity.configureHandoff(payload: payload, title: title)
    }
  }
}

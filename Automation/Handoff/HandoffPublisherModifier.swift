import Foundation
import SwiftUI

/// Reads the focused-scene navigation state and stamps an
/// `NSUserActivity` via SwiftUI's `.userActivity(_:isActive:_:)` so the
/// system can hand the route off to a peer device. Attach to the view
/// that owns the live profile session — the `AccountStore` /
/// `EarmarkStore` environment values are read for title lookup and
/// must be present.
struct HandoffPublisherModifier: ViewModifier {
  let profileID: UUID
  @Environment(AccountStore.self) private var accountStore
  @Environment(EarmarkStore.self) private var earmarkStore
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
        accounts: accountStore,
        earmarks: earmarkStore)
      activity.configureHandoff(payload: payload, title: title)
    }
  }
}

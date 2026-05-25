import Foundation

/// The payload exchanged between Moolah devices to resume a navigation
/// location via Handoff. Encoded as JSON into
/// `NSUserActivity.userInfo["payload"]`.
struct HandoffPayload: Codable, Equatable, Sendable {
  let profileID: UUID
  let destination: NavigationDestination
}

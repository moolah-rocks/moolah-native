import Foundation
import OSLog

private let logger = Logger(subsystem: "com.moolah.app", category: "Handoff")

extension NSUserActivity {

  /// Stamps every field required for Moolah's Handoff continuation.
  /// Centralised so the field map in the design doc stays in sync with
  /// the call sites.
  static func configureContinueActivity(
    _ activity: NSUserActivity,
    payload: HandoffPayload,
    title: String
  ) {
    activity.title = title
    activity.targetContentIdentifier = payload.profileID.uuidString
    activity.isEligibleForHandoff = true
    activity.isEligibleForSearch = false
    activity.isEligibleForPublicIndexing = false
    activity.requiredUserInfoKeys = ["payload"]
    do {
      let data = try JSONEncoder().encode(payload)
      activity.userInfo = ["payload": data]
    } catch {
      logger.error(
        "Failed to encode HandoffPayload: \(error.localizedDescription, privacy: .public)")
      activity.userInfo = [:]
    }
  }

  /// Decodes the payload from a continuation activity, or returns `nil`
  /// if the activity is malformed (missing key, unparseable JSON).
  var handoffPayload: HandoffPayload? {
    guard let data = userInfo?["payload"] as? Data else { return nil }
    return try? JSONDecoder().decode(HandoffPayload.self, from: data)
  }
}

import Foundation
import OSLog

private let logger = Logger(subsystem: "com.moolah.app", category: "Handoff")
private let encoder = JSONEncoder()
private let decoder = JSONDecoder()

extension NSUserActivity {

  /// Stamps every field required for Moolah's Handoff continuation.
  /// Centralised so the field map in the design doc stays in sync with
  /// the call sites.
  func configureHandoff(payload: HandoffPayload, title: String) {
    self.title = title
    targetContentIdentifier = payload.profileID.uuidString
    isEligibleForHandoff = true
    isEligibleForSearch = false
    isEligibleForPublicIndexing = false
    requiredUserInfoKeys = ["payload"]
    do {
      let data = try encoder.encode(payload)
      userInfo = ["payload": data]
    } catch {
      logger.error(
        "Failed to encode HandoffPayload: \(error.localizedDescription, privacy: .public)")
      userInfo = [:]
    }
  }

  /// Decodes the payload from a continuation activity, or returns `nil`
  /// if the activity is malformed (missing key, unparseable JSON).
  var handoffPayload: HandoffPayload? {
    guard let data = userInfo?["payload"] as? Data else { return nil }
    do {
      return try decoder.decode(HandoffPayload.self, from: data)
    } catch {
      logger.warning(
        "Failed to decode HandoffPayload: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }
}

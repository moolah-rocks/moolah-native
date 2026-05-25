import Foundation
import Testing

@testable import Moolah

@Suite("NSUserActivity Handoff")
struct NSUserActivityHandoffTests {

  private func samplePayload() throws -> HandoffPayload {
    HandoffPayload(
      profileID: try #require(UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
      destination: .account(try #require(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"))))
  }

  @Test("configureContinueActivity stamps every required field")
  func configureStampsFields() throws {
    let payload = try samplePayload()
    let activity = NSUserActivity(activityType: HandoffActivity.continueActivityType)
    NSUserActivity.configureContinueActivity(activity, payload: payload, title: "Chase Checking")

    #expect(activity.activityType == HandoffActivity.continueActivityType)
    #expect(activity.title == "Chase Checking")
    #expect(activity.targetContentIdentifier == payload.profileID.uuidString)
    #expect(activity.isEligibleForHandoff)
    #expect(!activity.isEligibleForSearch)
    #expect(!activity.isEligibleForPublicIndexing)
    #expect(activity.requiredUserInfoKeys == ["payload"])
    let payloadData = try #require(activity.userInfo?["payload"] as? Data)
    let decoded = try JSONDecoder().decode(HandoffPayload.self, from: payloadData)
    #expect(decoded == payload)
  }

  @Test("handoffPayload recovers an identical payload")
  func handoffPayloadRoundTrips() throws {
    let payload = try samplePayload()
    let activity = NSUserActivity(activityType: HandoffActivity.continueActivityType)
    NSUserActivity.configureContinueActivity(activity, payload: payload, title: "x")
    let recovered = try #require(activity.handoffPayload)
    #expect(recovered == payload)
  }

  @Test("handoffPayload returns nil when userInfo lacks the payload key")
  func handoffPayloadMissingKey() {
    let activity = NSUserActivity(activityType: HandoffActivity.continueActivityType)
    activity.userInfo = [:]
    #expect(activity.handoffPayload == nil)
  }

  @Test("handoffPayload returns nil for unparseable payload data")
  func handoffPayloadUnparseable() {
    let activity = NSUserActivity(activityType: HandoffActivity.continueActivityType)
    activity.userInfo = ["payload": Data([0x00, 0x01, 0x02])]
    #expect(activity.handoffPayload == nil)
  }
}

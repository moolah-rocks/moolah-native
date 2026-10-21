import Foundation
import MoolahMCP
import Testing

@testable import Moolah

@MainActor
struct MCPIntegrationDraftTests {
  @Test
  func requiresExplicitProfilesAndValidNamePermissionsAndExpiry() {
    let instant = Date(timeIntervalSince1970: 1_700_000_000)
    let draft = MCPIntegrationDraft(now: { instant })
    #expect(draft.profileIDs.isEmpty)
    #expect(!draft.scopes.contains(.transactionNotes))
    #expect(draft.validationMessage != nil)
    draft.label = "Fixture"
    draft.profileIDs = [UUID()]
    #expect(draft.validationMessage == nil)
    draft.label = String(repeating: "💰", count: 31)
    #expect(draft.validationMessage != nil)
    draft.label = "Fixture"
    draft.hasExpiry = true
    draft.expiry = instant
    #expect(draft.validationMessage != nil)
    draft.expiry = instant.addingTimeInterval(60)
    #expect(draft.validationMessage == nil)
    draft.scopes = []
    #expect(draft.validationMessage != nil)
    #expect(MCPServerPreferences.portValidationMessage("1024") == nil)
    #expect(MCPServerPreferences.portValidationMessage("65535") == nil)
    for invalid in ["0", "1023", "65536", "localhost", ""] {
      #expect(MCPServerPreferences.portValidationMessage(invalid) != nil)
    }
  }
}

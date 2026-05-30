import Testing

@testable import ImportExtensionKit

@Suite("InboxWriter.shared")
struct InboxWriterSharedTests {
  @Test("appGroupIdentifier is the canonical group")
  func appGroupIdentifier() {
    #expect(InboxWriter.appGroupIdentifier == "group.rocks.moolah.shared")
  }

  // On iOS (sandboxed simulator host), `containerURL(forSecurityApplicationGroupIdentifier:)`
  // returns nil for an unregistered group identifier — so `shared(...)` does too.
  // On macOS the test host is not sandboxed; Foundation returns a non-nil URL
  // under `~/Library/Group Containers/<id>/` whether or not the group is real.
  // The contract "returns nil when entitlements misconfigured" is only
  // observable on the sandboxed platform; macOS instead surfaces the
  // misconfiguration as a writer rooted under the wrong (unentitled) URL,
  // which the principal-side runtime sanity check (Task 15) catches.
  #if os(iOS)
    @Test("shared resolver returns nil when group container unavailable")
    func sharedNilWhenContainerMissing() {
      #expect(InboxWriter.shared(groupIdentifier: "group.does.not.exist") == nil)
    }
  #endif
}

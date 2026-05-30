#if os(macOS)
  import AppKit
  import Foundation
  import Testing

  @testable import Moolah

  @Suite("ProfileWindowLocator")
  @MainActor
  struct ProfileWindowLocatorTests {

    @Test("identifier is derived from the profile UUID")
    func identifierShape() throws {
      let profileID = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
      let identifier = ProfileWindowLocator.identifier(for: profileID)
      #expect(identifier.rawValue == "moolah.profile.11111111-1111-1111-1111-111111111111")
    }

    @Test("identifiers are equal for the same profile UUID")
    func identifierEquality() {
      let profileID = UUID()
      let first = ProfileWindowLocator.identifier(for: profileID)
      let second = ProfileWindowLocator.identifier(for: profileID)
      #expect(first == second)
    }

    @Test("identifiers differ between profile UUIDs")
    func identifierDiffers() {
      let first = ProfileWindowLocator.identifier(for: UUID())
      let second = ProfileWindowLocator.identifier(for: UUID())
      #expect(first != second)
    }

    @Test("existingWindow finds a window tagged with the matching identifier")
    func findsTaggedWindow() {
      let profileID = UUID()
      let window = NSWindow()
      window.identifier = ProfileWindowLocator.identifier(for: profileID)
      let other = NSWindow()
      other.identifier = NSUserInterfaceItemIdentifier("something.else")

      let found = ProfileWindowLocator.existingWindow(for: profileID, in: [other, window])
      #expect(found === window)
    }

    @Test("existingWindow returns nil when no window matches")
    func noMatchReturnsNil() {
      let window = NSWindow()
      window.identifier = ProfileWindowLocator.identifier(for: UUID())
      let result = ProfileWindowLocator.existingWindow(for: UUID(), in: [window])
      #expect(result == nil)
    }

    @Test("existingWindow returns nil for an empty window list")
    func emptyListReturnsNil() {
      let result = ProfileWindowLocator.existingWindow(for: UUID(), in: [])
      #expect(result == nil)
    }

    @Test("existingWindow ignores windows with no identifier")
    func ignoresUntaggedWindows() {
      let untagged = NSWindow()
      let profileID = UUID()
      let tagged = NSWindow()
      tagged.identifier = ProfileWindowLocator.identifier(for: profileID)

      let found = ProfileWindowLocator.existingWindow(for: profileID, in: [untagged, tagged])
      #expect(found === tagged)
    }

    // MARK: - duplicateWindow

    @Test("duplicateWindow returns nil when only currentWindow has the identifier")
    func noDuplicateWhenOnlyCurrentMatches() {
      let profileID = UUID()
      let current = NSWindow()
      current.identifier = ProfileWindowLocator.identifier(for: profileID)
      let untagged = NSWindow()

      let dup = ProfileWindowLocator.duplicateWindow(
        for: profileID, currentWindow: current, in: [current, untagged])
      #expect(dup == nil)
    }

    @Test("duplicateWindow finds the sibling window when another matches")
    func findsSiblingMatch() {
      let profileID = UUID()
      let current = NSWindow()
      let sibling = NSWindow()
      sibling.identifier = ProfileWindowLocator.identifier(for: profileID)

      let dup = ProfileWindowLocator.duplicateWindow(
        for: profileID, currentWindow: current, in: [current, sibling])
      #expect(dup === sibling)
    }

    @Test("duplicateWindow never returns currentWindow even when tagged")
    func ignoresSelfMatch() {
      let profileID = UUID()
      let current = NSWindow()
      current.identifier = ProfileWindowLocator.identifier(for: profileID)

      let dup = ProfileWindowLocator.duplicateWindow(
        for: profileID, currentWindow: current, in: [current])
      #expect(dup == nil)
    }

    @Test("duplicateWindow returns nil for an empty windows list")
    func emptyWindowsReturnsNil() {
      let current = NSWindow()
      let dup = ProfileWindowLocator.duplicateWindow(
        for: UUID(), currentWindow: current, in: [])
      #expect(dup == nil)
    }

    @Test("duplicateWindow ignores windows tagged for a different profile")
    func ignoresDifferentProfile() {
      let profileA = UUID()
      let profileB = UUID()
      let current = NSWindow()
      let sibling = NSWindow()
      sibling.identifier = ProfileWindowLocator.identifier(for: profileB)

      let dup = ProfileWindowLocator.duplicateWindow(
        for: profileA, currentWindow: current, in: [current, sibling])
      #expect(dup == nil)
    }

    // MARK: - anyProfileWindowPresent

    @Test("anyProfileWindowPresent is false for an empty windows list")
    func presenceEmptyList() {
      #expect(ProfileWindowLocator.anyProfileWindowPresent(in: []) == false)
    }

    @Test("anyProfileWindowPresent is false for windows with no identifier")
    func presenceUntaggedOnly() {
      let first = NSWindow()
      let second = NSWindow()
      #expect(ProfileWindowLocator.anyProfileWindowPresent(in: [first, second]) == false)
    }

    @Test("anyProfileWindowPresent is true when any window is profile-tagged")
    func presenceWithProfileTagged() {
      let untagged = NSWindow()
      let profileWindow = NSWindow()
      profileWindow.identifier = ProfileWindowLocator.identifier(for: UUID())
      #expect(
        ProfileWindowLocator.anyProfileWindowPresent(in: [untagged, profileWindow]) == true
      )
    }

    @Test("anyProfileWindowPresent ignores non-profile identifiers")
    func presenceIgnoresUnrelatedIdentifiers() {
      let about = NSWindow()
      about.identifier = NSUserInterfaceItemIdentifier("about")
      let settings = NSWindow()
      settings.identifier = NSUserInterfaceItemIdentifier("settings")
      #expect(ProfileWindowLocator.anyProfileWindowPresent(in: [about, settings]) == false)
    }
  }
#endif

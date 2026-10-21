import Foundation

extension SessionManager {
  func registerWindowSession(profileID: UUID, owner: UUID) {
    if let previous = windowSessionProfiles[owner], previous != profileID {
      releaseWindowSession(owner: owner)
    }
    windowSessionProfiles[owner] = profileID
  }

  func releaseWindowSession(owner: UUID) {
    guard let profileID = windowSessionProfiles.removeValue(forKey: owner) else { return }
    cleanUpUnownedSession(profileID: profileID)
  }

  /// Cached legacy callers (including iOS) retain their existing lifetime. macOS windows and
  /// service leases have explicit ownership, and share the normal final-owner cleanup path.
  func cleanUpUnownedSession(profileID: UUID) {
    guard sessions[profileID] != nil,
      !legacySessionProfiles.contains(profileID),
      !windowSessionProfiles.values.contains(profileID),
      readSessionOwners[profileID]?.isEmpty != false
    else { return }
    removeSession(for: profileID)
  }
}

import Foundation

extension SessionManager {
  /// Callers authorize the UUID first. This never opens a window or creates a profile session.
  func readProfileStatus(profileID: UUID, syncState: ReadSyncState? = nil) async throws
    -> ReadProfileStatusDTO
  {
    let profile: Profile?
    do { profile = try await profileIndexRepository.profile(forID: profileID) } catch {
      if error is CancellationError { throw CancellationError() }
      throw ReadQueryError.profileUnavailable
    }
    try Task.checkCancellation()
    guard let profile else {
      return ReadProfileStatusDTO(
        id: profileID,
        label: nil,
        baseInstrument: nil,
        readiness: "unavailable",
        syncState: "unknown"
      )
    }
    let readiness: String
    if profile.dataFormatVersion > DataFormatVersion.current {
      readiness = "incompatible"
    } else if let session = sessions[profileID] {
      if session.authStore.state == .signedOut {
        readiness = "signed_out"
      } else {
        readiness =
          readReadyProfiles.contains(profileID) && readSessionOwners[profileID]?.isEmpty == false
          ? "ready" : "initializing"
      }
    } else {
      readiness = "unavailable"
    }
    return ReadProfileStatusDTO(
      id: profileID,
      label: profile.label,
      baseInstrument: ReadInstrumentDTO(profile.instrument),
      readiness: readiness,
      syncState: readiness == "ready" ? (syncState ?? readSyncState).rawValue : "unknown"
    )
  }
}

import Foundation

extension SessionManager {
  /// The caller must authorize the explicit UUID before invoking this method.
  /// Reservations are retained across setup awaits so concurrent service owners cannot tear
  /// each other's setup down. No profile-name or current-window fallback is permitted.
  func acquireReadSession(
    profileID: UUID,
    owner: UUID
  ) async throws -> ProfileSession {
    let profile = try await readProfile(profileID: profileID)
    try Task.checkCancellation()
    let session: ProfileSession
    if let existing = sessions[profileID] {
      session = existing
    } else {
      session = try makeReadSession(for: profile)
    }
    readSessionOwners[profileID, default: []].insert(owner)
    do {
      try await session.setUp()
      try Task.checkCancellation()
      guard sessions[profileID] === session else { throw ReadQueryError.profileUnavailable }
      readReadyProfiles.insert(profileID)
      return session
    } catch {
      if sessions[profileID] === session {
        releaseReadSession(profileID: profileID, owner: owner)
      }
      if error is CancellationError { throw CancellationError() }
      throw ReadQueryError.profileUnavailable
    }
  }

  func releaseReadSession(profileID: UUID, owner: UUID) {
    readSessionOwners[profileID]?.remove(owner)
    guard readSessionOwners[profileID]?.isEmpty == true else { return }
    readSessionOwners.removeValue(forKey: profileID)
    readReadyProfiles.remove(profileID)
    cleanUpUnownedSession(profileID: profileID)
  }

  func readAccess(profileID: UUID) async throws -> ReadProfileAccess {
    let profile = try await readProfile(profileID: profileID)
    guard readReadyProfiles.contains(profileID),
      readSessionOwners[profileID]?.isEmpty == false,
      let session = sessions[profileID],
      let repository = session.backend.readQueries,
      session.authStore.state != .signedOut
    else { throw ReadQueryError.profileUnavailable }
    return ReadProfileAccess(
      profile: profile,
      repository: repository.using(defaultInstrument: profile.instrument),
      identity: session.readGeneration
    )
  }

  func validateReadAccess(_ access: ReadProfileAccess) async throws {
    let current = try await readAccess(profileID: access.profile.id)
    guard current.identity == access.identity,
      current.profile.currencyCode == access.profile.currencyCode
    else { throw ReadQueryError.profileUnavailable }
  }
}

extension SessionManager {
  private func readProfile(profileID: UUID) async throws -> Profile {
    let profile: Profile
    do {
      guard let current = try await profileIndexRepository.profile(forID: profileID) else {
        removeSession(for: profileID)
        syncCoordinator?.evictCachedState(for: profileID)
        throw ReadQueryError.profileUnavailable
      }
      profile = current
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ReadQueryError {
      throw error
    } catch {
      throw ReadQueryError.profileUnavailable
    }
    try Task.checkCancellation()
    guard profile.dataFormatVersion <= DataFormatVersion.current else {
      removeSession(for: profileID)
      syncCoordinator?.evictCachedState(for: profileID)
      recordReadIncompatibility(profile)
      throw ReadQueryError.profileIncompatible
    }
    return profile
  }
}

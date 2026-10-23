import Foundation

/// Sendable read dependencies, tied to one SessionManager-owned session instance.
struct ReadProfileAccess: Sendable {
  let syncState: ReadSyncState
  let profile: Profile
  let repository: any ReadQueryRepository
  let conversionService: any InstrumentConversionService
  let identity: UUID
}

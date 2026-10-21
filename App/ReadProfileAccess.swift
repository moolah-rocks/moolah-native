import Foundation

/// Sendable read dependencies, tied to one SessionManager-owned session instance.
struct ReadProfileAccess: Sendable {
  let profile: Profile
  let repository: any ReadQueryRepository
  let identity: UUID
}

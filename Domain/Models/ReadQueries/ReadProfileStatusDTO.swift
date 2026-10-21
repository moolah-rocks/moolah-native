import Foundation

/// Only metadata for an explicitly allowed profile; missing labels never default to another profile.
struct ReadProfileStatusDTO: Codable, Sendable {
  let id: UUID
  let label: String?
  let baseInstrument: ReadInstrumentDTO?
  let readiness: String
  let syncState: String
}

import Foundation

enum TaxOwnerKind: String, Codable, Sendable, CaseIterable {
  case individual
  case trust
}

struct TaxOwner: Identifiable, Codable, Sendable, Hashable {
  let id: UUID
  var name: String
  var kind: TaxOwnerKind

  init(
    id: UUID = UUID(),
    name: String,
    kind: TaxOwnerKind = .individual
  ) {
    self.id = id
    self.name = name
    self.kind = kind
  }
}

extension TaxOwner {
  static func defaultOwnerId(for profileId: UUID) -> UUID {
    UUID.deterministic(from: "tax-owner:default:\(profileId.uuidString)")
  }
}

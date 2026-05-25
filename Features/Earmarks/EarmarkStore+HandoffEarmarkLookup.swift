import Foundation

extension EarmarkStore: HandoffEarmarkLookup {
  func displayName(for id: UUID) -> String? {
    earmarks.by(id: id)?.name
  }
}

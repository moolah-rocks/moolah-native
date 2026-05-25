import Foundation

extension AccountStore: HandoffAccountLookup {
  func displayName(for id: UUID) -> String? {
    accounts.by(id: id)?.name
  }
}

import Foundation

/// Read-only window into account display names. Implemented by the real
/// `AccountStore` and by fakes in tests.
@MainActor
protocol HandoffAccountLookup {
  func displayName(for id: UUID) -> String?
}

import Foundation

/// Read-only window into earmark display names. Implemented by the real
/// `EarmarkStore` and by fakes in tests.
@MainActor
protocol HandoffEarmarkLookup {
  func displayName(for id: UUID) -> String?
}

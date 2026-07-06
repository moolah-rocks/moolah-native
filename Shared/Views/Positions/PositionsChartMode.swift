import Foundation

/// Distinguishes the aggregate (account-wide) chart from the
/// per-instrument chart. Each mode uses a different baseline:
/// `invested` for aggregate (remaining amount invested across the
/// account set, from the profile-wide `HoldingsCostLedger`), `cost`
/// for per-instrument (remaining cost of currently held lots).
enum PositionsChartMode: Sendable {
  case aggregate
  case perInstrument
}

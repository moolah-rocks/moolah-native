import Foundation

struct HoldingsCostLedgerMoveCandidate: Sendable, Hashable {
  let date: Date
  let source: HoldingsCostLedger.TouchKey
  let destination: HoldingsCostLedger.TouchKey
}

import Foundation

struct HoldingsCostLedgerDisposalCandidate: Sendable, Hashable {
  let date: Date
  let key: HoldingsCostLedger.TouchKey
}

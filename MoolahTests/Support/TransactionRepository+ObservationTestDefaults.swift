import Foundation

@testable import Moolah

// Test doubles in this target model transaction values, not the GRDB account
// and category metadata regions covered by the production repository. Forward
// their existing whole-value stream so unrelated store tests can satisfy the
// invalidation requirements without duplicating stream adapters in every fake.
extension TransactionRepository {
  func observeCostBasisRelevantChanges() -> AsyncStream<Void> {
    invalidations(from: observeAll(filter: TransactionFilter()))
  }

  func observeTaxRelevantChanges(filter: TransactionFilter) -> AsyncStream<Void> {
    invalidations(from: observeAll(filter: filter))
  }

  private func invalidations(
    from snapshots: AsyncStream<[Transaction]>
  ) -> AsyncStream<Void> {
    AsyncStream { continuation in
      let task = Task {
        for await _ in snapshots {
          guard !Task.isCancelled else { break }
          continuation.yield(())
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}

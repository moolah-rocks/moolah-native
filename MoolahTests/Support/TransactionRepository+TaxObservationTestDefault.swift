import Foundation

@testable import Moolah

// Test doubles in this target model transaction values, not the GRDB account
// and category metadata regions covered by the production repository. Forward
// their existing whole-value stream so unrelated store tests can satisfy the
// invalidation requirement without duplicating stream adapters in every fake.
extension TransactionRepository {
  func observeTaxRelevantChanges(filter: TransactionFilter) -> AsyncStream<Void> {
    let snapshots = observeAll(filter: filter)
    return AsyncStream { continuation in
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

// Backends/GRDB/Repositories/GRDBTaxOwnerRepository+Observation.swift

import GRDB

extension GRDBTaxOwnerRepository {
  func observeAll() -> AsyncStream<[TaxOwner]> {
    AsyncStream { continuation in
      let task = Task {
        let owners =
          ValueObservation
          .tracking(
            regions: [TaxOwnerRow.observableRegion, DeletionJournalRow.observableRegion]
          ) { database in
            try self.fetchRowsWithImplicitDefault(in: database)
          }
          .toRetryingAsyncStream(
            in: database,
            errorChannel: errorChannel,
            repoMethod: "GRDBTaxOwnerRepository.observeAll")
        for await value in owners {
          continuation.yield(value)
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}

// Backends/GRDB/Repositories/GRDBTaxOwnerRepository+Observation.swift

import GRDB

extension GRDBTaxOwnerRepository {
  func observeAll() -> AsyncStream<[TaxOwner]> {
    ValueObservation
      .tracking(
        regions: [TaxOwnerRow.observableRegion],
        fetch: { database in
          try TaxOwnerRow
            .order(TaxOwnerRow.Columns.name.asc)
            .fetchAll(database)
            .map { $0.toDomain() }
        }
      )
      .toRetryingAsyncStream(
        in: database,
        errorChannel: errorChannel,
        repoMethod: "GRDBTaxOwnerRepository.observeAll")
  }

  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}

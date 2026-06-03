import Foundation
import GRDB

// Reactive observation surface for `InsightDismissalRepository`. Same domain
// projection as `fetchAll()`: every `insight_dismissal` row, ordered by kind,
// mapped through `toDomain()` (unknown raw values dropped). See
// `GRDBAccountGroupRepository+Observation` for the error-handling contract.
extension GRDBInsightDismissalRepository {
  func observeAll() -> AsyncStream<[InsightDismissal]> {
    ValueObservation
      .tracking(
        regions: [InsightDismissalRow.observableRegion],
        fetch: { database in
          try InsightDismissalRow
            .order(InsightDismissalRow.Columns.kind.asc)
            .fetchAll(database)
            .compactMap { $0.toDomain() }
        }
      )
      .toRetryingAsyncStream(
        in: database,
        errorChannel: errorChannel,
        repoMethod: "GRDBInsightDismissalRepository.observeAll")
  }

  func observeErrors() -> AsyncStream<any Error> {
    errorChannel.stream
  }
}

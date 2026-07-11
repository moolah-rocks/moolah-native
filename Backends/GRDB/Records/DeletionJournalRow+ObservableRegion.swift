// Backends/GRDB/Records/DeletionJournalRow+ObservableRegion.swift

import GRDB

extension DeletionJournalRow {
  /// Observation region for tombstone state that can suppress implicit rows.
  /// Sync replay ordering (`queued_at`) is intentionally excluded.
  static var observableRegion: QueryInterfaceRequest<DeletionJournalRow> {
    all().select(Columns.zoneName, Columns.recordName, Columns.recordType)
  }
}

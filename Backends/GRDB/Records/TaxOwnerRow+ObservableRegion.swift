// Backends/GRDB/Records/TaxOwnerRow+ObservableRegion.swift

import GRDB

extension TaxOwnerRow {
  /// Observation region for user-visible tax owner fields. Excludes sync
  /// bookkeeping so CloudKit system-field updates do not refire owner lists.
  static var observableRegion: QueryInterfaceRequest<TaxOwnerRow> {
    select(Columns.id, Columns.recordName, Columns.name, Columns.kind)
  }
}

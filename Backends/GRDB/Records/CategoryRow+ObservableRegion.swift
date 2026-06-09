// Backends/GRDB/Records/CategoryRow+ObservableRegion.swift

import Foundation
import GRDB

extension CategoryRow {
  /// Column-restricted region UI `ValueObservation`s pass to
  /// `tracking(regions:fetch:)`. Excludes `encoded_system_fields` so
  /// CKSyncEngine's per-batch sync-bookkeeping write does not re-fire
  /// UI observers. See `AccountRow+ObservableRegion.swift` for the
  /// shared pattern and issue #865 for the motivation.
  static var observableRegion: QueryInterfaceRequest<CategoryRow> {
    let columns: [any SQLSelectable] = Columns.allCases
      .filter { $0 != .encodedSystemFields && $0 != .needsPush }
      .map { $0 as any SQLSelectable }
    return select(columns)
  }
}

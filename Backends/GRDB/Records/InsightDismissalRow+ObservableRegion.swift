import Foundation
import GRDB

extension InsightDismissalRow {
  /// Column-restricted region for UI `ValueObservation`s. Excludes
  /// `encoded_system_fields` so the per-batch sync-bookkeeping write
  /// CKSyncEngine performs after a successful send does not re-fire UI
  /// observers. `Columns: CaseIterable` means new columns auto-enrol.
  /// See issue #865.
  static var observableRegion: QueryInterfaceRequest<InsightDismissalRow> {
    let columns: [any SQLSelectable] = Columns.allCases
      .filter { $0 != .encodedSystemFields && $0 != .needsPush }
      .map { $0 as any SQLSelectable }
    return select(columns)
  }
}

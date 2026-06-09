// Backends/GRDB/Records/AccountRow+ObservableRegion.swift

import Foundation
import GRDB

extension AccountRow {
  /// Column-restricted region UI `ValueObservation`s pass to
  /// `tracking(regions:fetch:)`. Excludes `encoded_system_fields` and the
  /// local-only `needs_push` flag so the per-batch sync-bookkeeping
  /// writes CKSyncEngine / the apply + ack paths perform do not re-fire
  /// UI observers. See issues #865 and #1081. `Columns: CaseIterable`
  /// means new data columns auto-enrol — no duplicate allowlist to
  /// maintain.
  static var observableRegion: QueryInterfaceRequest<AccountRow> {
    let columns: [any SQLSelectable] = Columns.allCases
      .filter { $0 != .encodedSystemFields && $0 != .needsPush }
      .map { $0 as any SQLSelectable }
    return select(columns)
  }
}

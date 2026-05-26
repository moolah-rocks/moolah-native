import Foundation
import GRDB

extension AccountGroupRow {
  /// Column-restricted region UI `ValueObservation`s pass to
  /// `tracking(regions:fetch:)`. Excludes `encoded_system_fields` so the
  /// per-batch sync-bookkeeping write CKSyncEngine performs after a
  /// successful send does not re-fire UI observers. See issue #865.
  /// `Columns: CaseIterable` means new columns auto-enrol — no
  /// duplicate allowlist to maintain.
  static var observableRegion: QueryInterfaceRequest<AccountGroupRow> {
    let columns: [any SQLSelectable] = Columns.allCases
      .filter { $0 != .encodedSystemFields }
      .map { $0 as any SQLSelectable }
    return select(columns)
  }
}

// Backends/GRDB/Records/InvestmentValueRow+ObservableRegion.swift

import Foundation
import GRDB

extension InvestmentValueRow {
  /// Column-restricted region UI `ValueObservation`s pass to
  /// `tracking(regions:fetch:)`. See
  /// `AccountRow+ObservableRegion.swift` for the shared pattern and
  /// issue #865 for the motivation.
  static var observableRegion: QueryInterfaceRequest<InvestmentValueRow> {
    let columns: [any SQLSelectable] = Columns.allCases
      .filter { $0 != .encodedSystemFields && $0 != .needsPush }
      .map { $0 as any SQLSelectable }
    return select(columns)
  }
}

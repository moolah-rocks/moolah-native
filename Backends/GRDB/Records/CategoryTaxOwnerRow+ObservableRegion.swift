// Backends/GRDB/Records/CategoryTaxOwnerRow+ObservableRegion.swift

import Foundation
import GRDB

extension CategoryTaxOwnerRow {
  static var observableRegion: QueryInterfaceRequest<CategoryTaxOwnerRow> {
    all()
  }
}

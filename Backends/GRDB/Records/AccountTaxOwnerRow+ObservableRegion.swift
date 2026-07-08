// Backends/GRDB/Records/AccountTaxOwnerRow+ObservableRegion.swift

import Foundation
import GRDB

extension AccountTaxOwnerRow {
  static var observableRegion: QueryInterfaceRequest<AccountTaxOwnerRow> {
    all()
  }
}

// Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository+AliasedCryptoRegistrationProvider.swift

import Foundation
import GRDB

// MARK: - AliasedCryptoRegistrationProvider

extension GRDBInstrumentRegistryRepository: AliasedCryptoRegistrationProvider {
  /// Every crypto registration INCLUDING aliased (retired) rows. The one-shot
  /// identity migration needs the retired rows to derive the retired → canonical
  /// mapping, so it must NOT use `allCryptoRegistrations()` (which filters them
  /// out via `alias_of IS NULL`). Read-only; no alias predicate.
  func allCryptoRegistrationsIncludingAliased() async throws -> [CryptoRegistration] {
    try await database.read { database in
      let cryptoKind = Instrument.Kind.cryptoToken.rawValue
      let rows =
        try InstrumentRow
        .filter(InstrumentRow.Columns.kind == cryptoKind)
        .fetchAll(database)
      return try rows.compactMap { row in try Self.project(row: row) }
    }
  }
}

import CryptoKit
import Foundation
import GRDB

/// Stateless authoritative read facade over the profile's existing queue and instrument registry.
/// Immutable Sendable dependencies permit use off the UI actor without an isolation escape hatch.
final class GRDBReadQueryRepository {
  // MARK: - Cross-extension internals

  // Positions and Transactions share the queue, immutable lookup dependencies, clock,
  // revision validation and instrument mapping. No database objects escape read closures.
  let database: any DatabaseWriter
  let instrumentResolver: any InstrumentMapResolving
  let defaultInstrument: Instrument
  let epoch: String
  let now: @Sendable () -> Date

  init(
    database: any DatabaseWriter,
    instrumentResolver: any InstrumentMapResolving,
    defaultInstrument: Instrument,
    now: @escaping @Sendable () -> Date = { Date() },
    epoch: String = UUID().uuidString
  ) {
    self.database = database
    self.instrumentResolver = instrumentResolver
    self.defaultInstrument = defaultInstrument
    self.now = now
    self.epoch = epoch
  }
}

extension GRDBReadQueryRepository: ReadQueryRepository {
  func using(defaultInstrument: Instrument) -> any ReadQueryRepository {
    GRDBReadQueryRepository(
      database: database,
      instrumentResolver: instrumentResolver,
      defaultInstrument: defaultInstrument,
      now: now,
      epoch: epoch)
  }

  func accounts(
    includeHidden: Bool,
    page: ReadPageRequest
  ) async throws -> ReadPage<ReadAccountDTO> {
    let instruments = try await instrumentResolver.instrumentMap()
    let fingerprint = try self.instrumentFingerprint(instruments)
    return try await database.read { database in
      let revision = try self.revision(in: database, fingerprint: fingerprint, page: page)
      var request = AccountRow.order(AccountRow.Columns.id.asc)
      if !includeHidden { request = request.filter(AccountRow.Columns.isHidden == false) }
      if let after = page.after { request = request.filter(AccountRow.Columns.id > after.id) }
      let rows = try request.limit(page.limit + 1).fetchAll(database)
      let selected = rows.prefix(page.limit)
      let items = try selected.map { row in
        ReadAccountDTO(
          id: row.id,
          name: row.name,
          type: try AccountType.decoded(rawValue: row.type).rawValue,
          primaryInstrument: ReadInstrumentDTO(
            try self.instrument(
              row.instrumentId,
              in: instruments)),
          isHidden: row.isHidden)
      }
      return ReadPage(
        items: items,
        revision: revision,
        queriedAt: self.now(),
        nextKey: rows.count > page.limit ? selected.last.map { ReadPageKey(id: $0.id) } : nil)
    }
  }

  func categories(page: ReadPageRequest) async throws -> ReadPage<ReadCategoryDTO> {
    let fingerprint = try instrumentFingerprint([:])
    return try await database.read { database in
      let revision = try self.revision(in: database, fingerprint: fingerprint, page: page)
      var request = CategoryRow.order(CategoryRow.Columns.id.asc)
      if let after = page.after { request = request.filter(CategoryRow.Columns.id > after.id) }
      let rows = try request.limit(page.limit + 1).fetchAll(database)
      let selected = rows.prefix(page.limit)
      return ReadPage(
        items: selected.map {
          ReadCategoryDTO(
            id: $0.id,
            name: $0.name,
            parentID: $0.parentId)
        },
        revision: revision,
        queriedAt: self.now(),
        nextKey: rows.count > page.limit ? selected.last.map { ReadPageKey(id: $0.id) } : nil)
    }
  }

  func earmarks(page: ReadPageRequest) async throws -> ReadPage<ReadEarmarkDTO> {
    let instruments = try await instrumentResolver.instrumentMap()
    let fingerprint = try self.instrumentFingerprint(instruments)
    return try await database.read { database in
      let revision = try self.revision(in: database, fingerprint: fingerprint, page: page)
      var request = EarmarkRow.order(EarmarkRow.Columns.id.asc)
      if let after = page.after { request = request.filter(EarmarkRow.Columns.id > after.id) }
      let rows = try request.limit(page.limit + 1).fetchAll(database)
      let selected = Array(rows.prefix(page.limit))
      let positions = try self.earmarkPositions(
        ids: Set(selected.map(\.id)),
        database: database,
        instruments: instruments)
      let items = try selected.map { row in
        try self.earmarkDTO(row, instruments: instruments, positions: positions[row.id] ?? [])
      }
      return ReadPage(
        items: items,
        revision: revision,
        queriedAt: self.now(),
        nextKey: rows.count > page.limit ? selected.last.map { ReadPageKey(id: $0.id) } : nil)
    }
  }
}

extension GRDBReadQueryRepository {
  private func earmarkDTO(
    _ row: EarmarkRow,
    instruments: [String: Instrument],
    positions: [ReadQuantityDTO]
  ) throws -> ReadEarmarkDTO {
    let instrument = try self.instrument(row.instrumentId ?? defaultInstrument.id, in: instruments)
    let target = row.savingsTarget.map { storage in
      let amount = InstrumentAmount(storageValue: storage, instrument: instrument)
      return ReadQuantityDTO(quantity: amount.quantity, instrument: instrument)
    }
    return ReadEarmarkDTO(
      primaryInstrument: ReadInstrumentDTO(instrument),
      id: row.id,
      name: row.name,
      isHidden: row.isHidden,
      target: target,
      positions: positions)
  }

  /// DatabaseQueue owns one connection. Combine its write count with external-writer detection;
  /// the epoch invalidates all cursors after a session/repository is recreated.
  func revision(
    in database: Database,
    fingerprint: String,
    page: ReadPageRequest? = nil
  ) throws
    -> String
  {
    guard
      let changes = try Int64.fetchOne(
        database,
        sql: "SELECT total_changes()"),
      let version = try Int.fetchOne(database, sql: "PRAGMA data_version")
    else { throw ReadQueryError.profileUnavailable }
    let value = "\(epoch):\(version):\(changes):\(fingerprint)"
    if let expected = page?.revision, expected != value { throw ReadQueryError.cursorExpired }
    return value
  }

  /// Bind the exact lookup snapshot, including the current profile default. Unrelated
  /// registry edits conservatively expire cursors; no registry contents leave this facade.
  func instrumentFingerprint(_ instruments: [String: Instrument]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let values =
      [ReadInstrumentDTO(defaultInstrument)]
      + instruments.keys.sorted().compactMap { instruments[$0].map(ReadInstrumentDTO.init) }
    let data = Data("moolah-read-instruments-v1:".utf8) + (try encoder.encode(values))
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  func instrument(_ id: String, in instruments: [String: Instrument]) throws -> Instrument {
    if let instrument = instruments[id] { return instrument }
    if id == defaultInstrument.id { return defaultInstrument }
    if Locale.commonISOCurrencyCodes.contains(id) { return Instrument.fiat(code: id) }
    throw ReadQueryError.profileUnavailable
  }
}

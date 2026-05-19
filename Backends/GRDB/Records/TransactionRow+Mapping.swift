// Backends/GRDB/Records/TransactionRow+Mapping.swift

import Foundation

extension TransactionRow {
  /// The CloudKit recordType on the wire for this record. Frozen contract.
  static let recordType = "TransactionRecord"

  /// Canonical CloudKit `recordName` for a UUID-keyed transaction.
  static func recordName(for id: UUID) -> String {
    "\(recordType)|\(id.uuidString)"
  }

  /// Builds a row from a domain `Transaction`. The legs are NOT
  /// included; the repository persists them separately into the
  /// `transaction_leg` table.
  init(domain: Transaction) {
    self.id = domain.id
    self.recordName = Self.recordName(for: domain.id)
    self.date = domain.date
    self.payee = domain.payee
    self.notes = domain.notes
    self.recurPeriod = domain.recurPeriod?.rawValue
    self.recurEvery = domain.recurEvery
    // ImportOrigin denormalisation: `import_origin_kind` discriminates
    // the case. `.single` writes its origin into the eight outgoing
    // columns and clears the eight incoming columns; `.merged` writes
    // its outgoing side into the outgoing columns and its incoming
    // side into the incoming columns; nil clears all sixteen columns
    // and the kind.
    let outgoing: ImportOrigin?
    let incoming: ImportOrigin?
    switch domain.importOrigin {
    case .single(let origin):
      self.importOriginKind = "single"
      outgoing = origin
      incoming = nil
    case .merged(let merged):
      self.importOriginKind = "merged"
      outgoing = merged.outgoing
      incoming = merged.incoming
    case nil:
      self.importOriginKind = nil
      outgoing = nil
      incoming = nil
    }
    self.importOriginRawDescription = outgoing?.rawDescription
    self.importOriginBankReference = outgoing?.bankReference
    self.importOriginRawAmount = outgoing.map {
      NSDecimalNumber(decimal: $0.rawAmount).stringValue
    }
    self.importOriginRawBalance = outgoing?.rawBalance.map {
      NSDecimalNumber(decimal: $0).stringValue
    }
    self.importOriginImportedAt = outgoing?.importedAt
    self.importOriginImportSessionId = outgoing?.importSessionId
    self.importOriginSourceFilename = outgoing?.sourceFilename
    self.importOriginParserIdentifier = outgoing?.parserIdentifier
    self.importOriginIncomingRawDescription = incoming?.rawDescription
    self.importOriginIncomingBankReference = incoming?.bankReference
    self.importOriginIncomingRawAmount = incoming.map {
      NSDecimalNumber(decimal: $0.rawAmount).stringValue
    }
    self.importOriginIncomingRawBalance = incoming?.rawBalance.map {
      NSDecimalNumber(decimal: $0).stringValue
    }
    self.importOriginIncomingImportedAt = incoming?.importedAt
    self.importOriginIncomingImportSessionId = incoming?.importSessionId
    self.importOriginIncomingSourceFilename = incoming?.sourceFilename
    self.importOriginIncomingParserIdentifier = incoming?.parserIdentifier
    self.encodedSystemFields = nil
  }

  /// Reconstructs the outgoing `ImportOrigin?` from the eight
  /// `import_origin_*` columns iff every required field is present.
  /// One missing required field yields nil — the row was created
  /// without an outgoing origin. This avoids surfacing a half-formed
  /// origin if a write partially clears the columns.
  private func decodeOutgoing() -> ImportOrigin? {
    guard let rawDescription = importOriginRawDescription,
      let rawAmountStr = importOriginRawAmount,
      let rawAmount = Decimal(string: rawAmountStr),
      let importedAt = importOriginImportedAt,
      let sessionId = importOriginImportSessionId,
      let parserId = importOriginParserIdentifier
    else {
      return nil
    }
    return ImportOrigin(
      rawDescription: rawDescription,
      bankReference: importOriginBankReference,
      rawAmount: rawAmount,
      rawBalance: importOriginRawBalance.flatMap { Decimal(string: $0) },
      importedAt: importedAt,
      importSessionId: sessionId,
      sourceFilename: importOriginSourceFilename,
      parserIdentifier: parserId)
  }

  /// Reconstructs the incoming `ImportOrigin?` from the eight
  /// `import_origin_incoming_*` columns, mirroring `decodeOutgoing`.
  private func decodeIncoming() -> ImportOrigin? {
    guard let rawDescription = importOriginIncomingRawDescription,
      let rawAmountStr = importOriginIncomingRawAmount,
      let rawAmount = Decimal(string: rawAmountStr),
      let importedAt = importOriginIncomingImportedAt,
      let sessionId = importOriginIncomingImportSessionId,
      let parserId = importOriginIncomingParserIdentifier
    else {
      return nil
    }
    return ImportOrigin(
      rawDescription: rawDescription,
      bankReference: importOriginIncomingBankReference,
      rawAmount: rawAmount,
      rawBalance: importOriginIncomingRawBalance.flatMap { Decimal(string: $0) },
      importedAt: importedAt,
      importSessionId: sessionId,
      sourceFilename: importOriginIncomingSourceFilename,
      parserIdentifier: parserId)
  }

  /// Reconstructs `TransactionImportOrigin?` from the kind
  /// discriminator and the denormalised columns. A `"merged"` kind
  /// rebuilds both sides; any other kind — including a legacy null
  /// from a pre-v12 row — rebuilds the outgoing columns as `.single`,
  /// and yields nil when those columns are empty.
  private var importOrigin: TransactionImportOrigin? {
    if importOriginKind == "merged" {
      return .merged(MergedImportOrigin(outgoing: decodeOutgoing(), incoming: decodeIncoming()))
    }
    guard let outgoing = decodeOutgoing() else { return nil }
    return .single(outgoing)
  }

  /// Domain projection. Legs come from the repository's join on
  /// `transaction_leg` and are passed through here.
  ///
  /// Throws `BackendError.dataCorrupted` when `recurPeriod` is non-null
  /// but carries a raw value the compiled `RecurPeriod` enum doesn't
  /// recognise. A truly null `recurPeriod` column maps to nil — only
  /// the unrecognised-but-present case is corruption.
  func toDomain(legs: [TransactionLeg]) throws -> Transaction {
    Transaction(
      id: id,
      date: date,
      payee: payee,
      notes: notes,
      recurPeriod: try recurPeriod.map { try RecurPeriod.decoded(rawValue: $0) },
      recurEvery: recurEvery,
      legs: legs,
      importOrigin: importOrigin)
  }
}

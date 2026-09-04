import Foundation

/// Metadata a CSV import attaches to every `Transaction` it creates. Populated
/// at parse/persist time; `nil` for manually-created transactions.
///
/// `rawDescription`, `bankReference`, `rawAmount`, and `rawBalance` are the
/// unmodified values from the CSV row — rules operate on these fields so
/// import rules stay stable even after payee cleanup.
///
/// `importSessionId` identifies every transaction imported in a single ingest
/// event (one file drop, one scan pass, or one paste) for provenance.
struct ImportOrigin: Codable, Sendable, Hashable {
  let rawDescription: String
  let bankReference: String?
  let rawAmount: Decimal
  let rawBalance: Decimal?
  let importedAt: Date
  let importSessionId: UUID
  let sourceFilename: String?
  let parserIdentifier: String

  init(
    rawDescription: String,
    bankReference: String? = nil,
    rawAmount: Decimal,
    rawBalance: Decimal? = nil,
    importedAt: Date,
    importSessionId: UUID,
    sourceFilename: String? = nil,
    parserIdentifier: String
  ) {
    self.rawDescription = rawDescription
    self.bankReference = bankReference
    self.rawAmount = rawAmount
    self.rawBalance = rawBalance
    self.importedAt = importedAt
    self.importSessionId = importSessionId
    self.sourceFilename = sourceFilename
    self.parserIdentifier = parserIdentifier
  }
}

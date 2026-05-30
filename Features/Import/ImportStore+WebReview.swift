// swiftlint:disable multiline_arguments
// Reason: swift-format wraps long os_signpost and resolveProfile calls in
// ways the multiline_arguments rule disagrees with; matching the existing
// disable+reason pattern from MoolahApp+Setup.swift.

import Foundation
import ImportExtensionKit
import OSLog
import os

/// Web-import pipeline helpers for `ImportStore`. The public entry point
/// `startWebReview(payload:)` lives on the main `ImportStore.swift` so it
/// can mutate `private(set)` state (`isImporting`, `lastError`,
/// `recentSessions`) directly, matching the CSV `ingest(data:source:)`
/// pattern. Everything else — payload translation, parser-identifier
/// synthesis, staging-bytes encoding — lives here so the main file isn't
/// bloated with web-specific helpers.
extension ImportStore {

  // MARK: - Pipeline

  /// Pipeline run for a web payload. Equivalent to `runPipeline` for CSV,
  /// minus the tokenize / parser-select / parse stages — the payload is
  /// already structured, so we translate directly into `ParsedTransaction`
  /// and hand the same `candidates` array to the existing
  /// `resolveProfile` → `runDedup` → `persistCandidates` flow.
  func runWebPipeline(
    payload: ImportPayload, source: ImportSource, sessionId: UUID
  ) async throws -> ImportSessionResult {
    let pipelineSignpost = OSSignpostID(log: Signposts.importPipeline)
    os_signpost(
      .begin, log: Signposts.importPipeline, name: "ingestWeb",
      signpostID: pipelineSignpost)
    defer {
      os_signpost(
        .end, log: Signposts.importPipeline, name: "ingestWeb",
        signpostID: pipelineSignpost)
    }

    let parserIdentifier = Self.webParserIdentifier(for: payload.sourceHost)
    let headers = Self.webHeaderSignature(for: payload.sourceHost)
    let candidates = try buildWebCandidates(payload: payload)
    if candidates.isEmpty {
      return .imported(sessionId: sessionId, imported: [], skippedAsDuplicate: 0)
    }

    let stagingBytes = try Self.payloadStagingBytes(payload)
    let resolution = try await resolveProfile(
      data: stagingBytes,
      source: source,
      parserIdentifier: parserIdentifier,
      headers: headers,
      candidates: candidates)
    let resolvedProfile: CSVImportProfile
    switch resolution {
    case .routed(let profile):
      resolvedProfile = profile
    case .needsSetup(let pendingId):
      return .needsSetup(pendingId: pendingId)
    }

    let dedup = try await runDedup(
      candidates: candidates, accountId: resolvedProfile.accountId)
    let persisted = try await persistCandidates(
      dedup: dedup,
      resolvedProfile: resolvedProfile,
      sessionId: sessionId,
      source: source,
      parserIdentifier: parserIdentifier)
    await touchProfileLastUsedAt(resolvedProfile)

    return .imported(
      sessionId: sessionId,
      imported: persisted,
      skippedAsDuplicate: dedup.skipped.count)
  }

  // MARK: - Payload → ParsedTransaction translation

  /// Translate every row of the payload into a `ParsedTransaction`. The
  /// shape matches what `GenericBankCSVParser` emits for a one-leg cash row,
  /// so the rest of the pipeline (profile match, dedup, rules, persist) is
  /// completely unaware that the source isn't a CSV.
  func buildWebCandidates(
    payload: ImportPayload
  ) throws -> [ParsedTransaction] {
    var candidates: [ParsedTransaction] = []
    candidates.reserveCapacity(payload.rows.count)
    for (offset, row) in payload.rows.enumerated() {
      let rowIndex = offset + 1
      guard let date = Self.parseWebDate(row.date) else {
        throw IngestError.parse(
          .malformedRow(
            index: rowIndex, reason: "invalid date: \(row.date)",
            row: Self.rawRow(from: row)))
      }
      guard let amount = Self.parseWebAmount(row.amount) else {
        throw IngestError.parse(
          .malformedRow(
            index: rowIndex, reason: "invalid amount: \(row.amount)",
            row: Self.rawRow(from: row)))
      }
      let balance = row.balance.flatMap { Self.parseWebAmount($0) }
      let bankReference: String? = {
        guard let reference = row.reference else { return nil }
        let trimmed = reference.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
      }()
      let leg = ParsedLeg(
        accountId: nil,
        instrument: .AUD,
        quantity: amount,
        type: amount >= 0 ? .income : .expense,
        isInstrumentPlaceholder: true)
      candidates.append(
        ParsedTransaction(
          date: date,
          legs: [leg],
          rawRow: Self.rawRow(from: row),
          rawDescription: row.description,
          rawAmount: amount,
          rawBalance: balance,
          bankReference: bankReference))
    }
    return candidates
  }

  // MARK: - Helpers

  /// Parser identifier the web-import path stores on
  /// `CSVImportProfile.parserIdentifier`. Encodes the source host so two
  /// different sites never collide on the same profile.
  static func webParserIdentifier(for host: String) -> String {
    "web/\(host)"
  }

  /// Synthetic header signature for a web import. Two static slots —
  /// `"web"` and the host — give the matcher a stable
  /// `(parserIdentifier, headerSignature)` key per site, exactly as a CSV
  /// header row gives a per-bank key.
  static func webHeaderSignature(for host: String) -> [String] {
    ["web", host]
  }

  /// Encode the payload as JSON so the same staging-store machinery the CSV
  /// pipeline uses for Needs Setup / Failed Files can hold web payloads
  /// too. The bytes are recoverable on retry via `JSONDecoder.importPayload`.
  static func payloadStagingBytes(_ payload: ImportPayload) throws -> Data {
    try JSONEncoder.importPayload.encode(payload)
  }

  /// `[date, description, amount, balance, reference]` — gives diagnostics
  /// and the Failed Files panel something to render when a row trips the
  /// parser, mirroring the CSV path's `offendingRow`.
  static func rawRow(from row: ImportPayloadRow) -> [String] {
    [row.date, row.description, row.amount, row.balance ?? "", row.reference ?? ""]
  }

  // Cached formatters — `DateFormatter` and `ISO8601DateFormatter` are
  // expensive to construct, and `parseWebDate` runs once per imported
  // row. Both formatter classes are thread-safe for reads on Apple
  // platforms in the configurations used here.
  static let webDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  static let webISO8601Formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
  }()

  /// Accept the canonical `yyyy-MM-dd` form the extension emits and the
  /// full ISO-8601 form (`yyyy-MM-ddTHH:mm:ssZ`) as a fallback so a plugin
  /// that captures a timestamp instead of a date still imports.
  static func parseWebDate(_ field: String) -> Date? {
    let trimmed = field.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return nil }
    if let date = webDateFormatter.date(from: trimmed) { return date }
    return webISO8601Formatter.date(from: trimmed)
  }

  /// Decimal parsing that mirrors `GenericBankCSVParser.parseAmount`. The
  /// generic parser handles the same currency-prefix / thousand-separator /
  /// parenthesised-negative variants every site renders, so reusing the
  /// rules keeps web-amount semantics aligned with CSV-amount semantics.
  static func parseWebAmount(_ field: String) -> Decimal? {
    var value = field.trimmingCharacters(in: .whitespaces)
    if value.isEmpty { return nil }
    value = value.replacingOccurrences(of: "$", with: "")
    value = value.replacingOccurrences(of: "£", with: "")
    value = value.replacingOccurrences(of: "€", with: "")
    value = value.replacingOccurrences(of: ",", with: "")
    if value.hasPrefix("(") && value.hasSuffix(")") {
      value = "-" + value.dropFirst().dropLast()
    }
    return Decimal(string: value)
  }
}

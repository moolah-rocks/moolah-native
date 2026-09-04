import Foundation

/// Errors that can abort a pipeline run before reaching the persist stage.
/// `message` is safe for UI surfaces; `diagnosticDescription` retains the
/// actionable detail needed in logs.
enum IngestError: Error, Sendable {
  case decode(String)
  case parse(CSVParserError)
  case empty
  case other(String)

  var message: String {
    switch self {
    case .decode: return "Moolah couldn’t read the file."
    case .parse(let error):
      switch error {
      case .headerMismatch: return "Moolah couldn’t match the file’s columns."
      case let .malformedRow(index, reason, _):
        return "Row \(index) has \(Self.unreadableValueDescription(for: reason))."
      case .emptyFile: return "The file has no transaction rows."
      }
    case .empty: return "The file has no transaction rows."
    case .other: return "Moolah couldn’t finish importing the file."
    }
  }

  var diagnosticDescription: String {
    switch self {
    case .decode(let description): return "Decode failed: \(description)"
    case .parse(let error): return "Parse failed: \(String(describing: error))"
    case .empty: return "Import contained no transaction rows"
    case .other(let description): return "Import failed: \(description)"
    }
  }

  /// Which row the underlying parser error pointed at, if any. An empty
  /// `row` with a `nil` `index` means "no row info was captured"
  /// (e.g. an `.empty` / `.decode` / `.other` error, or a parser error
  /// other than `.malformedRow`).
  var offendingRow: (row: [String], index: Int?) {
    if case let .parse(parserError) = self,
      case let .malformedRow(index, _, row) = parserError
    {
      return (row, index)
    }
    return ([], nil)
  }

  private static func unreadableValueDescription(for reason: String) -> String {
    let normalized = reason.lowercased()
    if normalized.contains("date") { return "a date Moolah couldn’t read" }
    if normalized.contains("amount") { return "an amount Moolah couldn’t read" }
    if normalized.contains("units") { return "a unit quantity Moolah couldn’t read" }
    if normalized.contains("consideration") { return "a trade value Moolah couldn’t read" }
    return "a value Moolah couldn’t read"
  }
}

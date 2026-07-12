import Foundation

/// State of an in-progress profile export. Held on `ProfileSession` and
/// observed by the session's root view to show a progress sheet while
/// `ExportCoordinator.exportToFile` runs.
struct ActiveExport: Sendable, Equatable, Identifiable {
  let id = UUID()
  let profileLabel: String
  var stageLabel: String

  /// User-facing label for an `ExportCoordinator` / `DataExporter` step name.
  /// Falls back to a sentence-case form of the raw step for unknown values so
  /// new stages don't disappear silently from the UI.
  static func stageLabel(for step: String) -> String {
    switch step {
    case "starting": return "Starting…"
    case "accounts": return "Fetching accounts…"
    case "categories": return "Fetching categories…"
    case "earmarks": return "Fetching earmarks…"
    case "transactions": return "Fetching transactions…"
    case "encoding": return "Encoding file…"
    case "writing": return "Writing file…"
    default:
      guard let first = step.first else { return "Working…" }
      return first.uppercased() + step.dropFirst() + "…"
    }
  }
}

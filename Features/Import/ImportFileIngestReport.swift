import Foundation

/// Outcome of handing one or more files to the import pipeline.
struct ImportFileIngestReport: Sendable {
  let acceptedFileCount: Int
  let issues: [String]

  var userMessage: String? {
    guard !issues.isEmpty else { return nil }
    return issues.joined(separator: "\n")
  }
}

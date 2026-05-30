import Foundation

/// How the current ingest was initiated. Every entry point (folder watch,
/// file picker, drag-and-drop, paste) hands the orchestrator one of these so
/// the pipeline can pick the right file-deletion / disambiguation behaviour.
enum ImportSource: Sendable {

  /// User picked a file via `fileImporter`. `securityScoped == true` when
  /// the URL requires `startAccessingSecurityScopedResource`.
  case pickedFile(url: URL, securityScoped: Bool)

  /// A CSV appeared in a watched folder. `bookmark` is the security-scoped
  /// bookmark for the folder, used on iOS for catch-up scans.
  case folderWatch(url: URL, bookmark: Data?)

  /// A CSV was dropped onto a specific account (sidebar row or account
  /// transaction list). `forcedAccountId` bypasses profile matching and
  /// routes to that account directly.
  case droppedFile(url: URL, forcedAccountId: UUID?)

  /// Paste: in-memory text with no source file. `label` is a user-visible
  /// name for surfaces like the failed-files panel.
  case paste(text: String, label: String?)

  /// Re-entry for the Needs Setup flow. Preserves the original filename and
  /// (optional) source URL so `ImportOrigin.sourceFilename` carries the real
  /// name and `profile.deleteAfterImport` can still honour the toggle after
  /// the user completes setup.
  case reingestFromSetup(filename: String, sourceURL: URL?)

  /// A payload from the Safari web-import extension. `host` is the site the
  /// scrape came from (e.g. `"chase.com"`) and routes profile matching;
  /// `accountHint` is whatever the per-site plugin captured (e.g. the last
  /// four digits of an account number) and is surfaced in the review UI so
  /// the user can pick the right Moolah account on first use.
  case web(host: String, accountHint: String?)

  /// User-visible filename or paste label for diagnostics and the
  /// `ImportOrigin.sourceFilename` field.
  var filename: String? {
    switch self {
    case .pickedFile(let url, _),
      .folderWatch(let url, _),
      .droppedFile(let url, _):
      return url.lastPathComponent
    case .paste(_, let label):
      return label
    case .reingestFromSetup(let filename, _):
      return filename
    case .web(let host, _):
      return host
    }
  }

  /// Non-nil only for an explicit drop on a specific account.
  var forcedAccountId: UUID? {
    if case .droppedFile(_, let id) = self { return id }
    return nil
  }

  /// The source URL, if any — lets the pipeline delete the source file
  /// after a successful import when `profile.deleteAfterImport` is on.
  var sourceURL: URL? {
    switch self {
    case .pickedFile(let url, _),
      .folderWatch(let url, _),
      .droppedFile(let url, _):
      return url
    case .reingestFromSetup(_, let url):
      return url
    case .paste, .web:
      return nil
    }
  }
}
